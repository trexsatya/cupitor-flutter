// The page as rendered, for saving to a file.
//
// Injected on demand from the Tools drawer's "Save page HTML…" row, never on
// page load. Defines window.__cupitorExportHtml(strip), which returns the
// document's doctype plus the outerHTML of a deep clone of the root element.
// The live page is never touched.
//
// With `strip`, everything Cupitor added to the page is taken back out so the
// file is the page as the site rendered it. Injected elements are found by
// convention — an id or class starting with `__cup`, or a
// `data-cupitor-injected` attribute — so a new injection only has to follow
// the convention to be covered. The remote snippet names its own roots with
// the `cup-` prefix instead, so those are listed too.
(function () {
  if (window.__cupitorExportHtml) return;

  // Elements that exist only because Cupitor put them there.
  var INJECTED = [
    '[data-cupitor-injected]',
    '[id^="__cup"]',
    '[class^="__cup"]',
    '[class*=" __cup"]',
    '.cupitor-mask',
    // Roots the remote snippet builds: subtitle stylesheet, subtitle
    // sidebar, its modal, and the floating picker panel. Named exactly:
    // `cup-` is four characters a site can plausibly use for its own
    // markup, so nothing here matches on that prefix alone.
    '#cup-sub-css',
    '.cup-sub-sidebar',
    '.cup-sub-modal',
    '.cup-pc.cup-nolookup'
  ].join(', ');

  // Marks Cupitor leaves on elements the site owns. `cup-sub-` is the
  // snippet's own namespace; `cup-shrink-target` is the one loose name it
  // paints on the site's player.
  var CLASS_PREFIXES = ['cupitor-', 'cup-sub-'];
  var CLASS_NAMES = ['cup-shrink-target'];
  var ATTR_PREFIXES = ['data-cupitor-'];
  var ATTR_NAMES = ['data-cup-ann'];

  function marked(name, prefixes, names) {
    var i;
    for (i = 0; i < prefixes.length; i++) {
      if (name.indexOf(prefixes[i]) === 0) return true;
    }
    for (i = 0; i < names.length; i++) {
      if (name === names[i]) return true;
    }
    return false;
  }

  // Replace an element with plain text, in place.
  function unwrap(el, text) {
    var parent = el.parentNode;
    if (!parent) return;
    parent.replaceChild(el.ownerDocument.createTextNode(text), el);
  }

  function originalText(el) {
    var orig = el.getAttribute('data-cupitor-orig');
    return orig != null ? orig : (el.textContent || '');
  }

  // Split a style attribute into its declarations. Semicolons inside quotes
  // or parentheses — a data: URI, a content string — do not end one.
  function splitDeclarations(text) {
    var out = [], start = 0, depth = 0, quote = '', i;
    for (i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      if (quote) {
        if (ch === '\\') i++;
        else if (ch === quote) quote = '';
      } else if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (ch === '(') {
        depth++;
      } else if (ch === ')') {
        if (depth > 0) depth--;
      } else if (ch === ';' && depth === 0) {
        out.push(text.slice(start, i));
        start = i + 1;
      }
    }
    out.push(text.slice(start));
    return out;
  }

  // Take one declaration out of an element's inline style, leaving the rest
  // of the attribute — including declarations the engine does not recognise —
  // exactly as the site wrote it. An attribute left empty is removed.
  //
  // Done on the attribute text rather than through el.style: removing a
  // property through the CSSOM reserializes the whole block, which drops
  // declarations the engine did not parse and rewrites the site's spacing.
  function dropInlineProp(el, name) {
    if (!el) return;
    var text = el.getAttribute('style');
    if (text == null) return;
    var parts = splitDeclarations(text);
    var kept = [];
    for (var i = 0; i < parts.length; i++) {
      var colon = parts[i].indexOf(':');
      var head = colon < 0 ? '' : parts[i].slice(0, colon).trim().toLowerCase();
      if (head !== name) kept.push(parts[i]);
    }
    if (kept.length === parts.length) return;
    text = kept.join(';');
    if (text.trim() === '') el.removeAttribute('style');
    else el.setAttribute('style', text);
  }

  function strip(root) {
    var i, el;

    var injected = root.querySelectorAll(INJECTED);
    for (i = 0; i < injected.length; i++) {
      el = injected[i];
      if (el.parentNode) el.parentNode.removeChild(el);
    }

    // The snippet's picker-panel stylesheet carries no id of its own, so it
    // is recognised by an anonymous <style> holding a rule for the panel —
    // not by a passing mention of the name in a comment or a longer class.
    var styles = root.querySelectorAll('style:not([id])');
    for (i = 0; i < styles.length; i++) {
      if (/\.cup-pc\s*[{,]/.test(styles[i].textContent || '')) {
        if (styles[i].parentNode) styles[i].parentNode.removeChild(styles[i]);
      }
    }

    // A word rewritten by a text transform goes back to what the site had.
    // Before the word spans: a transform span can sit inside one.
    var xforms = root.querySelectorAll('.cupitor-xform');
    for (i = 0; i < xforms.length; i++) unwrap(xforms[i], originalText(xforms[i]));

    // utils.js wraps every word for tap-to-look-up; the site did not.
    var words = root.querySelectorAll('.clickable-word');
    for (i = 0; i < words.length; i++) unwrap(words[i], originalText(words[i]));

    // Find-in-page wraps each hit in its own <mark>.
    var marks = root.querySelectorAll('mark._fh');
    for (i = 0; i < marks.length; i++) unwrap(marks[i], marks[i].textContent || '');

    // Marks left on the site's own elements: classes and data attributes.
    // <html> carries them like any other element, and querySelectorAll on the
    // root does not return the root itself.
    var all = [root];
    var rest = root.querySelectorAll('*');
    for (i = 0; i < rest.length; i++) all.push(rest[i]);
    for (i = 0; i < all.length; i++) {
      el = all[i];
      if (el.classList && el.classList.length) {
        var drop = [];
        for (var c = 0; c < el.classList.length; c++) {
          if (marked(el.classList[c], CLASS_PREFIXES, CLASS_NAMES)) {
            drop.push(el.classList[c]);
          }
        }
        for (var d = 0; d < drop.length; d++) el.classList.remove(drop[d]);
        if (!el.classList.length) el.removeAttribute('class');
      }
      var attrs = el.attributes;
      var gone = [];
      for (var a = 0; a < attrs.length; a++) {
        if (marked(attrs[a].name, ATTR_PREFIXES, ATTR_NAMES)) gone.push(attrs[a].name);
      }
      for (var g = 0; g < gone.length; g++) el.removeAttribute(gone[g]);
    }

    // Inline properties Cupitor sets on the site's own elements: the page
    // zoom level on <html>, the snippet's video/subtitle split on <body>.
    dropInlineProp(root, 'zoom');
    dropInlineProp(root.querySelector('body'), '--cup-vid-h');

    // Unwrapped words are separate text nodes; merge them back into their
    // sentences so the file reads like the site's own markup.
    root.normalize();
  }

  // The file is written as UTF-8 whatever the page declared, and relative
  // links and images should still resolve when it is opened away from its
  // origin. A page that brought its own <base href> keeps it.
  function fixHead(clone) {
    var head = clone.querySelector('head');
    if (!head) {
      head = clone.ownerDocument.createElement('head');
      clone.insertBefore(head, clone.firstChild);
    }

    var metas = head.querySelectorAll('meta');
    for (var i = 0; i < metas.length; i++) {
      var equiv = metas[i].getAttribute('http-equiv');
      var declaresCharset = metas[i].hasAttribute('charset') ||
        (equiv && equiv.toLowerCase() === 'content-type');
      if (declaresCharset && metas[i].parentNode) {
        metas[i].parentNode.removeChild(metas[i]);
      }
    }
    var charset = clone.ownerDocument.createElement('meta');
    charset.setAttribute('charset', 'utf-8');
    head.insertBefore(charset, head.firstChild);

    if (head.querySelector('base[href]')) return;
    var base = clone.ownerDocument.createElement('base');
    base.setAttribute('href', window.location.href);
    head.insertBefore(base, charset.nextSibling);
  }

  function doctypeOf(dt) {
    if (!dt) return '';
    var out = '<!DOCTYPE ' + dt.name;
    if (dt.publicId) out += ' PUBLIC "' + dt.publicId + '"';
    if (dt.systemId) out += (dt.publicId ? '' : ' SYSTEM') + ' "' + dt.systemId + '"';
    return out + '>\n';
  }

  window.__cupitorExportHtml = function (stripInjections) {
    var clone = document.documentElement.cloneNode(true);
    if (stripInjections) strip(clone);
    fixHead(clone);
    return doctypeOf(document.doctype) + clone.outerHTML;
  };
})();
