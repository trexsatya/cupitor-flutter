// Cupitor frame agent. Bundled fallback from trexsatya.github.io/db/js/frame-boot.js.
//
// Injected by the host at DOCUMENT START into EVERY frame, via
// WebViewCompat.addDocumentStartJavaScript or macOS WKUserScript. This reaches a
// cross-origin iframe: page JavaScript cannot touch one from its parent, so an
// e-book reader served from a different subdomain than its host page (Studora
// renders ereader2.studora.se inside studora.se) is otherwise unreachable.
//
// Deliberately talks to the top frame with postMessage rather than through a
// JavaScript channel. Whether addJavascriptInterface exposes channels to
// cross-origin frames varies by WebView version; postMessage across origins is
// guaranteed. Only the top frame — running snippet.js — talks to the host.
//
// Protocol, all under the `__cupPC` key:
//   down   { op: 'arm', on: bool }        parent → children
//   up     { op: 'add', text }            a collected sentence
//   up     { op: 'selection', text, sentence, paragraph }
//                                          current selection, '' when cleared;
//                                          `text` is the raw pick, the other
//                                          two are the granularities offered
//   up     { op: 'hello' }                a frame arrived; asks for arm state
//   up     { op: 'miss', why }            a tap resolved no sentence
//   up     { op: 'diag', info }           counters, so failures are readable
//
// Every frame relays: arm messages downward, everything else upward. Nested
// frames therefore work without the top frame knowing the tree.
(function () {
  // A breadcrumb trail on the page, written before anything that can return
  // early. The log channel may not be attached to the document yet at document
  // start, so a report that depends on it proves nothing when it is missing —
  // this is readable later, by snippet.js, from whatever world snippet.js runs
  // in. If snippet.js cannot see this, the two are not sharing a world, and
  // that alone explains why a flag set here is invisible there.
  try {
    window.__cupFrameBootDiag = window.__cupFrameBootDiag || [];
    window.__cupFrameBootDiag.push(
      'ran href=' + String(location.href).slice(0, 120) +
      ' top=' + (window.top === window) +
      ' channel=' + (typeof window.SnippetLogChannel));
  } catch (_) {}

  if (window.__cupFrameBoot) return;
  window.__cupFrameBoot = 1;

  // ---- YouTube ad pruning -------------------------------------------------
  //
  // Deliberately above the top-frame return below, because it is needed in
  // both places. YouTube is watched two ways: as an ordinary page in the main
  // WebView, and as an <iframe> inside the study app's player. The host also
  // injects this per navigation, but that injection reaches a main frame only
  // and lands after the document has begun parsing — so it never sees the
  // iframe at all, and on a first watch page it can lose the race to
  // YouTube's own inline config assignment. Here it is document-start in
  // every frame, which is the only place both of those hold.
  //
  // Same technique as uBlock Origin's `json-prune`: the player decides where
  // to splice ads by reading named fields off its config, so the fields are
  // removed before it can read them.
  function note(msg) {
    try { window.__cupFrameBootDiag.push(msg); } catch (_) {}
  }

  function installYouTubeAdPrune() {
    if (!location.hostname || location.hostname.indexOf('youtube.com') < 0) {
      note('prune skipped: host=' + location.hostname);
      return;
    }
    if (window._ytAdPruneInstalled) { note('prune skipped: already installed'); return; }
    window._ytAdPruneInstalled = 1;
    note('prune installing');

    var AD_KEYS = [
      'playerAds', 'adPlacements', 'adSlots', 'adServingData',
      'adBreakHeartbeatParams', 'importantForAds',
    ];
    // Endpoints whose responses carry the config. Every video after the first
    // one in a session arrives through these rather than through the inline
    // script.
    var AD_ENDPOINTS = [
      '/youtubei/v1/player',
      '/youtubei/v1/next',
      '/youtubei/v1/reel/reel_item_watch',
      // m.youtube.com asks for the whole watch page here instead of calling
      // /player, so on a phone this is the only one of these that ever fires.
      '/youtubei/v1/get_watch',
    ];

    // Containers the config is nested inside. Descending by name rather than
    // walking the whole tree: the payload is large, and deleting anything
    // called adSlots wherever it appears risks taking a part of the page with
    // it. get_watch wraps both of these, which /player does not.
    var AD_CONTAINERS = ['playerResponse', 'response'];

    function prune(obj, depth) {
      if (!obj || typeof obj !== 'object') return;
      // A cap rather than a visited set: the nesting here is three deep at
      // most, and a self-referencing payload must not become a hung player.
      if ((depth || 0) > 4) return;
      if (Object.prototype.toString.call(obj) === '[object Array]') {
        for (var n = 0; n < obj.length; n++) prune(obj[n], (depth || 0) + 1);
        return;
      }
      for (var i = 0; i < AD_KEYS.length; i++) {
        if (AD_KEYS[i] in obj) { try { delete obj[AD_KEYS[i]]; } catch (_) {} }
      }
      for (var c = 0; c < AD_CONTAINERS.length; c++) {
        var inner = obj[AD_CONTAINERS[c]];
        if (inner && inner !== obj) prune(inner, (depth || 0) + 1);
      }
    }

    function carriesAds(url) {
      for (var i = 0; i < AD_ENDPOINTS.length; i++) {
        if (url.indexOf(AD_ENDPOINTS[i]) >= 0) return true;
      }
      return false;
    }

    // Reporting, because "ads are showing" has three unrelated causes that
    // look identical from the sofa: this never ran, it ran and found nothing
    // to delete because the fields were renamed, or it deleted everything it
    // knows about and the ads were stitched into the video stream upstream
    // where no amount of deleting reaches them. Only the log tells them apart.
    //
    // The channel exists in the main frame of the app's own WebView and not in
    // a cross-origin iframe, so this is quiet exactly where it cannot work.
    function report(msg) {
      try { window.SnippetLogChannel.postMessage('log|[yt] ' + msg); } catch (_) {}
    }

    // Top-level keys that look ad-related, so a field YouTube has renamed
    // shows up by name instead of as silence.
    function adish(obj) {
      var out = [];
      try {
        for (var k in obj) { if (/ad/i.test(k)) out.push(k); }
      } catch (_) {}
      return out;
    }

    // Every innertube endpoint seen, and which transport carried it, whether
    // or not we pruned it. This is what turns "the config never reached us"
    // from a deduction into a list: if the player config is still arriving by
    // some route we do not watch, its name shows up here.
    var seenKeys = {};
    var seenCount = 0;
    function noteSeen(url, via) {
      try {
        if (seenCount >= 8) return;
        var s = String(url);
        if (s.indexOf('/youtubei/v1/') < 0) return;
        var key = via + ' ' + s.replace(/^https?:\/\/[^/]+/, '').split('?')[0];
        if (seenKeys[key]) return;
        seenKeys[key] = 1;
        seenCount++;
        report('saw ' + key);
      } catch (_) {}
    }

    // The top-level key names, because two rounds of guessing the shape of
    // this payload have now cost two deploys. Names are cheap and they end
    // the guessing: whatever container the config is really in, it is one of
    // these.
    function keyList(obj) {
      var out = [];
      try {
        for (var k in obj) {
          if (out.length >= 14) { out.push('...'); break; }
          out.push(String(k).slice(0, 40));
        }
      } catch (_) {}
      return out.join(',');
    }

    // What the ad keys look like in one container, so a renamed field shows
    // up by name instead of as silence.
    function describe(label, obj) {
      if (!obj || typeof obj !== 'object') return '';
      var isArr = Object.prototype.toString.call(obj) === '[object Array]';
      var present = [];
      for (var i = 0; i < AD_KEYS.length; i++) {
        if (AD_KEYS[i] in obj) present.push(AD_KEYS[i]);
      }
      return ' ' + label + (isArr ? '[array:' + obj.length + ']' : '') +
             '{known=' + (present.join(',') || 'NONE') +
             ' adish=' + (adish(obj).join(',') || 'none') +
             ' keys=' + (keyList(obj) || 'none') + '}';
    }

    // Capped per endpoint, not just in total. get_watch is re-requested every
    // few seconds on a watch page, and in one run it used every slot before
    // /next was ever reported — the cap hid the very thing it was meant to
    // leave room for.
    var reportedBy = {};
    var reportedTotal = 0;
    function reportResponse(url, body, via) {
      // Total: this runs inside a property setter that the page's own script
      // triggers, so anything escaping here surfaces as a failure in YouTube's
      // code. Diagnostics must never be able to break the thing they watch.
      try {
        if (reportedTotal >= 10) return;
        if (!body || typeof body !== 'object') return;
        var endpoint = String(url).replace(/^https?:\/\/[^/]+/, '').split('?')[0];
        if ((reportedBy[endpoint] || 0) >= 2) return;
        reportedBy[endpoint] = (reportedBy[endpoint] || 0) + 1;
        reportedTotal++;
        var msg = endpoint + ' via=' + (via || 'fetch') + describe('top', body);
        for (var c = 0; c < AD_CONTAINERS.length; c++) {
          msg += describe(AD_CONTAINERS[c], body[AD_CONTAINERS[c]]);
        }
        report(msg.slice(0, 900));
      } catch (_) {}
    }

    // Anything an inline script already assigned before us. At document start
    // there should be nothing, but this costs nothing and covers the case
    // where the host injected us late.
    report('prune installed on ' + location.hostname +
           (window.top === window ? ' (page)' : ' (iframe)'));
    try {
      if (window.ytInitialPlayerResponse) {
        reportResponse('inline/ytInitialPlayerResponse', window.ytInitialPlayerResponse);
      }
      prune(window.ytInitialPlayerResponse);
    } catch (_) {}

    // Future assignments — the watch page's inline script, and every SPA
    // navigation that re-assigns it.
    try {
      var _ipr = window.ytInitialPlayerResponse;
      Object.defineProperty(window, 'ytInitialPlayerResponse', {
        configurable: true,
        // At document start this is the normal path: we are in place before
        // the watch page's inline script assigns it, which is the whole point
        // of running here rather than from the host.
        //
        // The store happens outside the guard on purpose. Pruning is a best
        // effort and may fail; holding on to what the page assigned is not
        // optional, because a getter that then returns undefined takes the
        // player down with it. Ads are a nuisance, a dead player is not.
        set: function (v) {
          try { reportResponse('inline/assigned', v); prune(v); } catch (_) {}
          _ipr = v;
        },
        get: function () { return _ipr; },
      });
    } catch (_) { /* may already be non-configurable */ }

    // ---- XMLHttpRequest ----------------------------------------------------
    //
    // m.youtube.com fetches its player config over XHR, not fetch: on the
    // mobile watch page the /youtubei/v1/player response never reaches the
    // fetch wrapper below and the inline global is never assigned, yet the
    // player starts. Wrapping only fetch covers the desktop site and misses
    // the phone entirely.
    //
    // The response is rewritten through a getter defined on the instance
    // rather than from a 'load' listener. Listeners run in registration order,
    // and the page registers its own before we would get to add ours — by the
    // time we rewrote anything the page would already have read it. A getter
    // does not care who reads first.
    try {
      var XHR = window.XMLHttpRequest;
      var proto = XHR && XHR.prototype;
      var textDesc = proto && Object.getOwnPropertyDescriptor(proto, 'responseText');
      var respDesc = proto && Object.getOwnPropertyDescriptor(proto, 'response');
      if (proto && textDesc && textDesc.get) {
        var origOpen = proto.open;
        var origSend = proto.send;

        proto.open = function (method, url) {
          try { this.__cupUrl = String(url == null ? '' : url); } catch (_) {}
          return origOpen.apply(this, arguments);
        };

        proto.send = function () {
          try {
            var url = this.__cupUrl || '';
            noteSeen(url, 'xhr');
            if (carriesAds(url)) {
              var self = this;
              // undefined = not computed yet, null = nothing we can do with it.
              var cache;
              function pruned() {
                if (cache !== undefined) return cache;
                cache = null;
                var raw;
                try { raw = textDesc.get.call(self); } catch (_) { return cache; }
                if (typeof raw !== 'string' || raw.charAt(0) !== '{') return cache;
                try {
                  var j = JSON.parse(raw);
                  reportResponse(url, j, 'xhr');
                  prune(j);
                  cache = JSON.stringify(j);
                } catch (_) { cache = null; }
                return cache;
              }
              Object.defineProperty(this, 'responseText', {
                configurable: true,
                get: function () {
                  var v = pruned();
                  return v === null ? textDesc.get.call(self) : v;
                },
              });
              if (respDesc && respDesc.get) {
                Object.defineProperty(this, 'response', {
                  configurable: true,
                  get: function () {
                    var orig = respDesc.get.call(self);
                    var rt = '';
                    try { rt = self.responseType || ''; } catch (_) {}
                    // Only the text-shaped ones get the rewritten body. A
                    // blob or an arraybuffer is not ours to reinterpret.
                    if (rt === '' || rt === 'text') {
                      var v = pruned();
                      return v === null ? orig : v;
                    }
                    if (rt === 'json' && orig && typeof orig === 'object') {
                      try {
                        reportResponse(url, orig, 'xhr/json');
                        prune(orig);
                      } catch (_) {}
                    }
                    return orig;
                  },
                });
              }
            }
          } catch (_) { /* never block the request itself */ }
          return origSend.apply(this, arguments);
        };
      }
    } catch (_) {}

    if (typeof window.fetch !== 'function') return;
    var _origFetch = window.fetch;
    window.fetch = function (input, init) {
      var url = '';
      try {
        url = typeof input === 'string' ? input : (input && input.url) || '';
      } catch (_) {}
      var p = _origFetch.call(this, input, init);
      // Not a thenable means something else has already replaced fetch with
      // something we do not understand. Hand its result back untouched.
      if (!p || typeof p.then !== 'function') return p;
      noteSeen(url, 'fetch');
      if (!carriesAds(url)) return p;
      return p.then(function (response) {
        // Returning the untouched response on any failure: a page with ads is
        // a far better outcome than a page whose player got a broken body.
        try {
          return response.clone().text().then(function (text) {
            try {
              var json = JSON.parse(text);
              reportResponse(url, json, 'fetch');
              prune(json);
              return new Response(JSON.stringify(json), {
                status: response.status,
                statusText: response.statusText,
                headers: response.headers,
              });
            } catch (_) { return response; }
          }, function () { return response; });
        } catch (_) { return response; }
      });
    };
  }
  // Named, not swallowed. An injected document-start script has no URL, so
  // anything thrown out of here reaches the page's own error handler as the
  // browser's opaque "Script error." with no file and no line — indistinguish-
  // able from the dozens a site like YouTube throws on its own. Reporting it
  // under our own name is the difference between a lead and a shrug.
  try {
    installYouTubeAdPrune();
  } catch (e) {
    try {
      window.SnippetLogChannel.postMessage(
        'warn|[yt] prune install failed: ' + ((e && e.message) || e));
    } catch (_) {}
  }

  // The top document gets snippet.js the ordinary way; this agent exists only
  // for frames, and doing both would install two of everything.
  if (window.top === window) return;

  var MIN_CHARS = 2;
  var armed = false;
  var sawArm = false;
  // Bumped on every arm change. The poller records which generation it
  // consumed a selection under, so arming while text is already selected
  // collects it instead of treating it as spent.
  var armGen = 0;

  // There is no console to read inside a cross-origin frame on a phone, and
  // "it doesn't work" has at least four distinct causes here: the script never
  // ran, arm never arrived, events never reached us, or resolution failed.
  // These counters are what tell them apart — they surface in the app's
  // "Page & frame report".
  var diag = {
    tstart: 0, tend: 0, clicks: 0, taps: 0,
    adds: 0, misses: 0, arms: 0, polls: 0, sels: 0,
    hadSel: 0, lastWhy: '', url: '',
  };
  try { diag.url = String(location.href).slice(0, 120); } catch (_) {}

  function up(msg) {
    try { parent.postMessage({ __cupPC: msg }, '*'); } catch (_) {}
  }

  function down(msg) {
    for (var i = 0; i < window.frames.length; i++) {
      try { window.frames[i].postMessage({ __cupPC: msg }, '*'); } catch (_) {}
    }
  }

  window.addEventListener('message', function (ev) {
    var d = ev && ev.data && ev.data.__cupPC;
    if (!d || !d.op) return;
    if (d.op === 'arm') {
      // Only the parent arms us: without this, any nested third-party frame
      // could arm its siblings with the app's own chip switched off. Written
      // as "present and wrong" rather than "not parent" on purpose — a
      // WebView that delivers no ev.source must not lose arming, which would
      // silently disable the whole feature.
      if (ev.source && ev.source !== parent) return;
      var was = armed;
      armed = !!d.on;
      diag.arms++;
      sawArm = true;
      // On any real change, in either direction. What must not bump it is a
      // REPEAT of the same value, which every frame's `hello` re-broadcast
      // produces. Bumping only when arming left the mirror broken: disarming
      // with text still selected reported nothing ever again.
      if (armed !== was) armGen++;
      down(d);              // keep nested frames in step
      return;
    }
    // Anything else came from a child on its way to the top.
    if (d.op === 'add' || d.op === 'selection' || d.op === 'hello' ||
        d.op === 'miss' || d.op === 'diag' || d.op === 'lookup') up(d);
  });

  var SENT_RE = /[^.!?…]+[.!?…]*\s*/g;

  function norm(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }

  // ---------------------------------------------------------------------------
  // Reading the page's text. Kept in step with the same block in
  // db/js/src/60-page-capture.js — this file is injected natively into
  // cross-origin frames and cannot import from the bundle, so the reading
  // rules live twice. Change one, change the other; the two feed the same
  // capture and a difference between them shows up as the same sentence
  // arriving in two shapes depending on where it was picked.
  // ---------------------------------------------------------------------------

  // Like norm, but keeping the line breaks a selection already carries:
  // Selection.toString() puts a newline where the layout draws one.
  function normLines(s) {
    return String(s || '')
      .replace(/\r\n?/g, '\n')
      .split('\n')
      .map(function (row) { return row.replace(/[^\S\n]+/g, ' ').trim(); })
      .filter(Boolean)
      .join('\n');
  }

  // For comparing two readings of the same text when only the words matter.
  function flat(s) { return norm(String(s || '').replace(/\n/g, ' ')); }

  var NOT_TEXT = /^(?:SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/;
  var BLOCK_ISH =
    /^(?:ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|BR|DD|DIV|DL|DT|FIELDSET|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TR|UL)$/;
  var OWN_LINE_DISPLAY =
    /^(?:block|flex|grid|list-item|table|table-row|table-caption|flow-root)$/;

  var styleCache = null;
  function styleOf(el) {
    if (styleCache && styleCache.has && styleCache.has(el)) return styleCache.get(el);
    var cs = null;
    try {
      var win = (el.ownerDocument && el.ownerDocument.defaultView) || window;
      cs = win.getComputedStyle(el);
    } catch (_) { cs = null; }
    if (styleCache && styleCache.set) styleCache.set(el, cs);
    return cs;
  }

  // Does this element start a line where it sits?
  function startsOwnLine(el) {
    var tag = el.tagName || '';
    var cs = styleOf(el);
    var d = cs ? (cs.display || '') : '';
    if (!d) return BLOCK_ISH.test(tag);
    if (d === 'none') return false;
    if (tag === 'BR') return true;
    if ((cs.cssFloat || cs.float || 'none') !== 'none') return false;
    if (cs.position === 'absolute' || cs.position === 'fixed') return false;
    if (!OWN_LINE_DISPLAY.test(d)) return false;
    var ps = el.parentElement ? styleOf(el.parentElement) : null;
    var pd = ps ? (ps.display || '') : '';
    if (pd === 'flex' || pd === 'inline-flex') {
      return /^column/.test(ps.flexDirection || '');
    }
    return true;
  }

  // Keeps a box of its own but shares the line: a table cell, a flex-row item.
  function sharesLineOwnBox(el) {
    var cs = styleOf(el);
    var d = cs ? (cs.display || '') : '';
    if (!d) return /^(?:TD|TH|CAPTION)$/.test(el.tagName || '');
    if (d === 'none') return false;
    if (/^table-(?:cell|caption)$/.test(d)) return true;
    var ps = el.parentElement ? styleOf(el.parentElement) : null;
    var pd = ps ? (ps.display || '') : '';
    if ((pd === 'flex' || pd === 'inline-flex') && !/^column/.test(ps.flexDirection || '')) {
      return true;
    }
    return false;
  }

  // A block's text as it is READ, plus where a caret sits inside it.
  // textContent cannot answer this: it drops a <br> and runs two paragraphs
  // together with nothing between them. The caret is measured in the same pass
  // that builds the text, so the offset stays measured rather than searched
  // for. `at` is -1 when the walk never reached the caret.
  function readBlock(root, stopNode, stopOffset) {
    var text = '';
    var at = -1;
    function last() { return text ? text.charAt(text.length - 1) : ''; }
    function addBreak() {
      if (!text) return;
      while (text && last() === ' ') text = text.slice(0, -1);
      if (last() !== '\n') text += '\n';
    }
    function addGap() {
      if (!text || last() === ' ' || last() === '\n') return;
      text += ' ';
    }
    // ws: 'collapse' | 'lines' (pre-line) | 'keep' (pre, pre-wrap, break-spaces)
    function addText(s, ws) {
      for (var i = 0; i < s.length; i++) {
        var ch = s.charAt(i);
        if (ws !== 'collapse' && ch === '\n') { addBreak(); continue; }
        if (ws !== 'keep' && /\s/.test(ch)) {
          if (!text || last() === ' ' || last() === '\n') continue;
          text += ' ';
          continue;
        }
        text += ch;
      }
    }
    function walk(node) {
      var i;
      if (node.nodeType === 3) {
        var parent = node.parentElement;
        var cs = parent ? styleOf(parent) : null;
        if (cs && cs.visibility === 'hidden') return;
        var white = cs ? (cs.whiteSpace || '') : '';
        var ws = /^(?:pre|pre-wrap|break-spaces)$/.test(white) ? 'keep'
          : (white === 'pre-line' ? 'lines' : 'collapse');
        var s = String(node.nodeValue || '');
        if (node === stopNode) {
          var cut = Math.max(0, Math.min(Number(stopOffset) || 0, s.length));
          addText(s.slice(0, cut), ws);
          at = text.length;
          addText(s.slice(cut), ws);
        } else {
          addText(s, ws);
        }
        return;
      }
      if (node.nodeType !== 1) return;
      if (NOT_TEXT.test(node.tagName || '')) return;
      var ecs = styleOf(node);
      if (ecs && ecs.display === 'none') return;
      var ownLine = startsOwnLine(node);
      var ownBox = !ownLine && sharesLineOwnBox(node);
      if (ownLine) addBreak();
      if (ownBox) addGap();
      var kids = node.childNodes;
      for (i = 0; i < kids.length; i++) {
        if (node === stopNode && i === Number(stopOffset)) at = text.length;
        walk(kids[i]);
      }
      if (node === stopNode && Number(stopOffset) >= kids.length) at = text.length;
      if (ownLine) addBreak();
      if (ownBox) addGap();
    }
    try { styleCache = new Map(); } catch (_) { styleCache = null; }
    try { walk(root); } catch (_) { /* keep whatever was read */ }
    styleCache = null;
    text = text.replace(/\s+$/, '');
    return { text: text, at: at < 0 ? -1 : Math.min(at, text.length) };
  }

  function caretRangeAt(x, y) {
    try {
      if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y);
      if (document.caretPositionFromPoint) {
        var p = document.caretPositionFromPoint(x, y);
        if (!p) return null;
        var r = document.createRange();
        r.setStart(p.offsetNode, p.offset);
        r.collapse(true);
        return r;
      }
    } catch (_) {}
    return null;
  }

  // The sentence under a tap, without requiring a selection the reader may not
  // permit. Blink offers sentence granularity on Selection.modify, which is
  // exactly this job; splitting the tapped text node is the fallback.
  var lastWhy = '';

  function resolveFrom(range) {
    try {
      var sel = window.getSelection();
      if (sel) {
        sel.removeAllRanges();
        sel.addRange(range);
        sel.modify('move', 'backward', 'sentenceboundary');
        sel.modify('extend', 'forward', 'sentence');
        var t = normLines(sel.toString());
        if (t.length >= MIN_CHARS) return t;
      }
    } catch (_) {}
    try {
      var node = range.startContainer;
      if (!node || node.nodeType !== 3) return '';
      var raw = String(node.textContent || '');
      var off = range.startOffset;
      var m;
      SENT_RE.lastIndex = 0;
      while ((m = SENT_RE.exec(raw)) !== null) {
        if (off >= m.index && off <= m.index + m[0].length) {
          var s2 = norm(m[0]);
          if (s2.length >= MIN_CHARS) return s2;
        }
      }
      return norm(raw);
    } catch (_) { return ''; }
  }

  // A finger is not a caret. Taps land in line gaps, on padding, and between
  // words, where caretRangeFromPoint returns nothing — so probe a little way
  // above and below before giving up.
  function sentenceAt(x, y) {
    var offsets = [0, -6, 6, -12, 12];
    var sawCaret = false;
    // resolveFrom below rewrites the selection on every probe, so a tap that
    // resolves nothing would otherwise leave a stray one-word selection behind
    // and destroy whatever the user actually had selected.
    var saved = null;
    try {
      var s0 = window.getSelection();
      if (s0 && s0.rangeCount) saved = s0.getRangeAt(0).cloneRange();
    } catch (_) {}
    var found = '';
    for (var i = 0; i < offsets.length; i++) {
      var range = caretRangeAt(x, y + offsets[i]);
      if (!range) continue;
      sawCaret = true;
      var t = resolveFrom(range);
      if (t) { found = t; break; }
    }
    // ALWAYS, success included. Returning early used to leave the selection
    // set to the sentence resolveFrom fabricated, which the poller then read
    // back as if the user had selected it. handleTapAt clears deliberately
    // when it banks.
    try {
      var s1 = window.getSelection();
      if (s1) {
        s1.removeAllRanges();
        if (saved) s1.addRange(saved);
      }
    } catch (_) {}
    if (found) return found;
    // 'no caret' means the point is not over text the engine can address at
    // all — a canvas, an overlay, or a shadow root. 'no text' means it is over
    // text but nothing came back, which is a resolution problem, not a
    // reachability one. The distinction decides what to try next.
    lastWhy = sawCaret ? 'no text' : 'no caret';
    diag.lastWhy = lastWhy;
    return '';
  }

  // The sentence spanning a character offset in a block of text.
  function sentenceAtOffset(raw, at) {
    if (!raw) return '';
    if (at >= raw.length) at = raw.length - 1;
    if (at < 0) return '';
    var m;
    SENT_RE.lastIndex = 0;
    while ((m = SENT_RE.exec(raw)) !== null) {
      // readBlock has already collapsed whatever the layout collapses, so
      // only the ends need tidying — flattening would throw away the breaks.
      if (at >= m.index && at < m.index + m[0].length) return m[0].replace(/^\s+|\s+$/g, '');
    }
    return '';
  }

  // Expand a selection to its sentence WITHOUT touching the selection.
  //
  // The polling path below must not mutate what the reader put there:
  // Selection.modify would fight the reader's own highlight palette and
  // re-trigger the very poll that called it. So this only reads.
  //
  // Readers routinely wrap each word in its own element, so the sentence is
  // almost never inside a single text node — climb to an ancestor holding
  // enough text, then find where in it the selection starts.
  //
  // The position is MEASURED with a scratch range, never searched for. A word
  // occurs many times in a paragraph, so matching the selected text against
  // the block's text picks the first occurrence rather than the one under the
  // user's finger — "cat" in "The cat is black. The cat sat." would collect
  // the wrong sentence every time. Range.toString() and textContent share the
  // same text-node semantics, so the length of the text before the selection
  // IS its offset — which also keeps this honest where innerText would not:
  // it ignores text-transform and hidden subtrees.
  function sentenceAroundSelection(sel) {
    var range, pick;
    try {
      if (!sel || sel.isCollapsed || !sel.rangeCount) return '';
      range = sel.getRangeAt(0);
      pick = normLines(sel.toString());
    } catch (_) { return ''; }
    if (pick.length < MIN_CHARS) return '';

    var node = range.startContainer;
    var block = node && (node.nodeType === 1 ? node : node.parentElement);
    // Climb past the per-word inline elements. A paged reader can make each
    // LINE its own block, so keep going until there is room for a sentence.
    for (var i = 0; block && i < 8; i++) {
      if (block.tagName === 'BODY') break;
      if ((block.textContent || '').length >= 80) break;
      if (!block.parentElement) break;
      block = block.parentElement;
    }
    if (!block) return pick;
    var read = readBlock(block, range.startContainer, range.startOffset);
    if (!read.text || read.at < 0) return pick;

    var s = sentenceAtOffset(read.text, read.at);
    // The sentence wins only if it actually contains what was selected;
    // otherwise the selection spans more than one and shrinking it would throw
    // away text the user deliberately picked.
    if (s.length >= MIN_CHARS && flat(s).indexOf(flat(pick)) !== -1) return s;
    return pick;
  }

  // Tags that genuinely mark a paragraph. ARTICLE / SECTION / MAIN are
  // deliberately absent: they are containers, and treating one as a paragraph
  // would hand back the whole chapter.
  var PARA_TAGS = /^(?:P|LI|BLOCKQUOTE|DD|DT|TD|TH|FIGCAPTION|H[1-6])$/;

  // The block of prose containing the selection, read without touching it.
  //
  // The nearest real paragraph tag wins. A reader that wraps every word — or
  // every LINE — in its own element would otherwise give back one line, so the
  // fallback is the nearest ancestor holding a paragraph's worth of text.
  function paragraphAroundSelection(sel) {
    var node;
    try {
      if (!sel || sel.isCollapsed || !sel.rangeCount) return '';
      node = sel.getRangeAt(0).startContainer;
    } catch (_) { return ''; }
    var el = node && (node.nodeType === 1 ? node : node.parentElement);
    var fallback = null;
    for (var i = 0; el && i < 12; i++) {
      if (el.tagName === 'BODY') break;
      if (PARA_TAGS.test(el.tagName || '')) {
        var t = readBlock(el).text;
        if (t.length >= MIN_CHARS) return t.slice(0, 4000);
      }
      // A ceiling as well as a floor: per-line markup with no paragraph tag
      // jumps from a 40-character line straight to the chapter container, and
      // "+ Paragraph" would then bank a chapter. Nothing paragraph-sized means
      // the button stays hidden, which is the honest answer.
      if (!fallback) {
        var len = (el.textContent || '').length;
        if (len >= 200 && len <= 2000) fallback = el;
      }
      if (!el.parentElement) break;
      el = el.parentElement;
    }
    return fallback ? readBlock(fallback).text.slice(0, 4000) : '';
  }

  function handleTapAt(ev, x, y) {
    diag.taps++;
    var el = ev.target;
    if (el && el.closest &&
        el.closest('a,button,input,textarea,select,[role="button"]')) return;
    var text = sentenceAt(x, y);
    if (!text || text.length < MIN_CHARS) {
      // Say so rather than staying silent: an unexplained no-op is what makes
      // this feel unreliable even when it is working as designed. Leave the
      // event alone so the reader's own tap behaviour still happens.
      diag.misses++;
      up({ op: 'miss', why: lastWhy || 'empty' });
      return;
    }
    ev.preventDefault();
    ev.stopPropagation();
    diag.adds++;
    up({ op: 'add', text: text });
    clearSel();
  }

  function clearSel() {
    try {
      var sel = window.getSelection();
      if (sel && sel.removeAllRanges) sel.removeAllRanges();
    } catch (_) {}
  }

  // The event-independent path, and the one to trust in a reader.
  //
  // Every tap-based approach here has to win a fight with the reader's own
  // gesture handling, and loses it in at least one of the reader's two layout
  // modes. Polling the selection picks no fight at all: whatever the reader
  // does with the event, if the user ends up with text selected — including
  // by the reader's own long-press-then-palette behaviour, which selects a
  // real DOM range — we see it and can read it.
  var pollLast = '';     // what the previous tick saw
  var pollDone = '';     // what has already been acted on
  var lookupSent = '';   // last text reported upward for lookup
  var doneGen = -1;      // the arm generation it was acted on under

  function pollSelection() {
    diag.polls++;
    var txt = '';
    var sel = null;
    try {
      sel = window.getSelection();
      // rangeCount first: Selection.toString() flushes layout, and this runs
      // every 350ms whether or not anything is selected.
      if (sel && sel.rangeCount && !sel.isCollapsed) txt = normLines(sel.toString());
    } catch (_) {}
    if (txt.length < MIN_CHARS) {
      if (pollLast || pollDone) {
        pollLast = '';
        pollDone = '';
        lookupSent = '';
        up({ op: 'selection', text: '' });
      }
      return;
    }
    diag.hadSel = 1;
    // Reported on FIRST sight and for lookup only, ahead of the settling gate:
    // collecting needs a stable selection, looking a word up does not. Sent
    // only when it changes — this runs three times a second per frame.
    if (txt !== lookupSent) {
      lookupSent = txt;
      // A dictionary lookup wants the words, not the shape.
      up({ op: 'lookup', text: flat(txt) });
    }
    // Two identical ticks means the drag has finished. Without this, every
    // intermediate selection during a drag would be collected as its own
    // sentence.
    if (txt !== pollLast) { pollLast = txt; return; }
    if (txt === pollDone && doneGen === armGen) return;
    pollDone = txt;
    doneGen = armGen;
    // Widen ONLY when collecting. This used to sit above the branch, so a
    // plain selection in a reader travelled up as its whole sentence — and
    // the host's lookup button then looked up the sentence instead of the
    // word the user had picked. Mirror of the same rule in
    // 60-page-capture.js's poller: a deliberate drag is what the user meant.
    if (armed) {
      var sentence = '';
      try { sentence = sentenceAroundSelection(sel); } catch (_) {}
      if (!sentence) sentence = txt;
      diag.adds++;
      // Collect without clearing: the selection is the reader's, and wiping it
      // would close the palette the user is looking at. pollDone is what stops
      // the next tick adding the same sentence again.
      //
      // `raw` carries what was actually selected, because `text` has been
      // widened to a sentence for the basket and lookup must not inherit that.
      // Deliberately not posting `selection` as well: that would set the top
      // frame's "+ Add sentence" chip, offering to bank what was just banked.
      up({ op: 'add', text: sentence, raw: txt });
    } else {
      // Both granularities, resolved here because only this frame can read its
      // own DOM. `text` stays the raw pick — the host's lookup wants the word
      // that was selected, not a widening of it.
      var pickSentence = '';
      var pickPara = '';
      try { pickSentence = sentenceAroundSelection(sel); } catch (_) {}
      try { pickPara = paragraphAroundSelection(sel); } catch (_) {}
      if (!pickSentence) pickSentence = txt;
      diag.sels++;
      up({
        op: 'selection',
        text: txt,
        sentence: pickSentence,
        paragraph: pickPara,
      });
    }
  }

  var tapStart = null;

  function start() {
    // Readers disable selection so long-press stays theirs for page turns,
    // which is why dragging to select fails inside them.
    try {
      var st = document.createElement('style');
      st.textContent =
        '*, *::before, *::after { -webkit-user-select: text !important;' +
        ' user-select: text !important; }';
      (document.head || document.documentElement).appendChild(st);
    } catch (_) {}

    // On WINDOW, in capture phase, and on touch rather than click. Three
    // separate reasons, each of which alone breaks this:
    //   - window capture is the first stop in the event path; a reader that
    //     binds there and stops propagation makes a document-level listener
    //     invisible;
    //   - capture phase runs before the target's own handlers;
    //   - a reader that calls preventDefault() for its page turns cancels the
    //     synthesized click outright, so no click listener ever runs.
    window.addEventListener('touchstart', function (ev) {
      diag.tstart++;
      if (!armed) return;
      var t = ev.changedTouches && ev.changedTouches[0];
      tapStart = t ? { x: t.clientX, y: t.clientY, at: Date.now() } : null;
    }, true);

    window.addEventListener('touchend', function (ev) {
      diag.tend++;
      if (!armed || !tapStart) return;
      var t = ev.changedTouches && ev.changedTouches[0];
      if (!t) { tapStart = null; return; }
      var dx = Math.abs(t.clientX - tapStart.x);
      var dy = Math.abs(t.clientY - tapStart.y);
      var dt = Date.now() - tapStart.at;
      tapStart = null;
      // A drag is the reader's page turn and a long press is a selection
      // attempt; neither is a request to collect.
      if (dx > 12 || dy > 12 || dt > 600) return;
      handleTapAt(ev, t.clientX, t.clientY);
    }, true);

    // Mouse and stylus, and WebViews that synthesize only mouse events. When
    // touchend already handled the tap it called preventDefault, so no click
    // follows; when it could not resolve a sentence, this gets a second go and
    // the top frame rejects a repeat of the same text anyway.
    window.addEventListener('click', function (ev) {
      diag.clicks++;
      if (!armed) return;
      handleTapAt(ev, ev.clientX, ev.clientY);
    }, true);

    // The poll is the load-bearing path; these just make it react instantly
    // to a selection that has already settled.
    document.addEventListener('selectionchange', pollSelection);
    document.addEventListener('mouseup', pollSelection);
    setInterval(pollSelection, 350);

    // Only while actually collecting. `sawArm` proves the top frame runs
    // pageCapture and that our messages arrive; `armed` keeps this from
    // being perpetual traffic in every frame of every page, since nothing
    // reads it the rest of the time.
    setInterval(function () {
      if (!sawArm || !armed) return;
      up({ op: 'diag', info: diag });
    }, 2000);

    // Retract any chip a PREVIOUS document in this frame raised. A reader
    // turning the page replaces its document, and the fresh one starts with no
    // selection to notice going away — so the chip stayed up backed by text
    // nobody can see any more. The frame's WindowProxy survives the
    // navigation, so the top frame still recognises us as its owner.
    up({ op: 'selection', text: '' });
    // The top frame may have been armed before this frame existed.
    up({ op: 'hello' });
    // A frame that loads before the top frame's snippet.js gets no answer to
    // that first hello, and would then never report. Keep asking until the
    // top frame replies.
    var helloTries = 0;
    var helloTimer = setInterval(function () {
      if (sawArm || ++helloTries > 20) { clearInterval(helloTimer); return; }
      up({ op: 'hello' });
    }, 1000);
  }

  // The reading rules are duplicated from db/js/src/60-page-capture.js, so
  // db/js/page-capture.test.mjs drives both through the same fixtures and
  // fails when they drift apart.
  window.__cupFrameBootRead = { readBlock: readBlock, normLines: normLines, flat: flat };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
