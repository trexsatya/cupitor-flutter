// Sentence-tagging companion to utils.js.
//
// Lives inside both the main WebView and the EPUB reader's WebView.
// Three responsibilities:
//   1. When capture mode is ON, route a word tap to the bottom-sheet
//      capture flow on the Dart side (instead of normal lookup).
//   2. On Dart's request, segment the surrounding block into sentences,
//      extend the selection by Prev/Next, paint a temporary highlight.
//   3. After a page load, accept Dart's snapshot of tagged sentences
//      and paint permanent highlights; apply / clear the filter fade.
//
// Identity rules and the _fp helper must agree byte-for-byte with
// lib/db.dart#fp. A startup self-test runs both implementations against
// the same corpus and logs a mismatch via SnippetLogChannel in debug.
// See docs/superpowers/specs/2026-06-24-sentence-tagging-design.md.

(function () {
  if (window.__cupitorSentenceTagLoaded) return;
  window.__cupitorSentenceTagLoaded = true;

  // ---------- Module state ----------

  // Dart flips this via window.__cupitorSetCaptureMode(active).
  // utils.js reads it to decide where to route a word tap.
  window.__cupitorCaptureMode = false;

  // Transient per-page state — wiped on page reload (since the script
  // re-injects on every navigation in the same WebView).
  var captureCounter = 0;
  var captureState = {};   // sentenceId -> {blockEl, sentStart, sentEnd, fullSents, range}
  var committedTags = {};  // sentenceId -> [tagColors]
  var rehydrated = [];     // [{id, text, prevFp, nextFp, mask, tagIds, tagColors}]
  var filterTagIds = null; // null = no filter; Set otherwise
  var masksVisible = false;
  // dbid -> { id, tagIds:[], colors:[], spans:[span,...], mask:'' }.
  // Source of truth for which group covers which spans. Span attributes
  // (data-cupitor-dbid CSV, tagids CSV, mask text) are derived from this.
  var tagSets = {};
  // run-key ("dbid:idxStart-idxEnd") -> { el, dbid }. Each injected
  // .cupitor-mask spans a contiguous run of .clickable-word elements
  // where one group "owns" the mask (longest-wins on shared spans).
  var maskInjections = {};
  // 'block' = use the tapped word's nearest block ancestor as the
  // segmentation scope (Intl.Segmenter runs over that block's text).
  // Default. Wrong on sites that wrap each printed LINE into its own
  // block (e.g. litteraturbanken's Angular SPA) — sentences span
  // multiple "blocks" and capture/rehydrate fails to find them whole.
  // 'document' = use document.body as the scope. Segmenter runs over
  // the whole page text; sentences are detected even across the per-
  // line wrapper spans. Slower per tap but more accurate on those
  // sites. Dart sets this on each page load via the setting.
  var segmentationScope = 'block';

  function nextSid() { return 's_' + (++captureCounter); }

  // ---------- Text transformation rules ----------

  // Dart pushes the per-language rule set into window.__cupitorTextTransforms
  // ({ "sv": [{type,pattern,replacement}, ...], ... }). We pick the ruleset
  // for the current document's language and rewrite text on the page so the
  // reader sees the transformed form — while snapshotting the original text
  // onto `data-cupitor-orig` on the wrapping unit so tag identity (which
  // fingerprints against original text) stays intact.
  function currentLangPrimary() {
    var raw = (document.documentElement && document.documentElement.lang) ||
              (navigator && navigator.language) || '';
    return String(raw).toLowerCase().split(/[-_]/)[0] || '';
  }
  function escapeRegex(s) {
    return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  function compileSubstringRules(rules) {
    var out = [];
    for (var i = 0; i < (rules || []).length; i++) {
      var r = rules[i];
      if (!r || r.type !== 'substring' || !r.pattern) continue;
      // Whole-word mode wraps the pattern in Unicode-aware negative
      // lookarounds so an "af" rule matches the standalone token "af"
      // but not "afton". `\b` alone won't do — it treats non-ASCII
      // letters like å/ä/ö as non-word, so \baf\b would incorrectly
      // match inside "åaf". \p{L}\p{M}\p{N} covers letters, marks, and
      // digits across scripts; underscore is added so it behaves like
      // programming word boundaries.
      var wholeWord = r.wholeWord !== false; // default true
      var src = escapeRegex(r.pattern);
      var flags = 'g';
      if (wholeWord) {
        src = '(?<![\\p{L}\\p{M}\\p{N}_])' + src + '(?![\\p{L}\\p{M}\\p{N}_])';
        flags = 'gu';
      }
      out.push({
        re: new RegExp(src, flags),
        to: r.replacement != null ? String(r.replacement) : '',
      });
    }
    return out;
  }
  function applyRulesToString(text, compiled) {
    if (!compiled.length) return text;
    var out = text;
    for (var i = 0; i < compiled.length; i++) {
      out = out.replace(compiled[i].re, compiled[i].to);
    }
    return out;
  }
  // Read the ORIGINAL (pre-transform) text of an element. If we've
  // already transformed inside it, the snapshot lives on
  // data-cupitor-orig; else the current textContent is the original.
  function originalTextOf(el) {
    if (!el) return '';
    var snap = el.getAttribute && el.getAttribute('data-cupitor-orig');
    return snap != null ? snap : (el.textContent || '');
  }
  window.__cupitorApplyTextTransforms = function () {
    ensureStyles();
    if (window.__cupitorTransformsEnabled === false) return;
    var lang = currentLangPrimary();
    var all = (window.__cupitorTextTransforms || {});
    var rules = all[lang] || [];
    var compiled = compileSubstringRules(rules);
    if (!compiled.length) return;
    // Apply per .clickable-word — each is a single-word text node, so a
    // substring replace on textContent is safe and preserves the word-tap
    // handler wiring. Untagged short words / punctuation between spans
    // stay original, which keeps blockWordIndex + sentence segmentation
    // stable when combined with the data-cupitor-orig fallback.
    var spans = document.querySelectorAll('span.clickable-word');
    for (var i = 0; i < spans.length; i++) {
      var span = spans[i];
      var orig = span.getAttribute('data-cupitor-orig');
      if (orig == null) orig = span.textContent || '';
      var next = applyRulesToString(orig, compiled);
      if (next !== span.textContent) {
        if (span.getAttribute('data-cupitor-orig') == null) {
          span.setAttribute('data-cupitor-orig', orig);
        }
        span.textContent = next;
        span.classList.add('cupitor-xform');
        span.setAttribute('title', orig);
      }
    }
  };
  // Undo whatever __cupitorApplyTextTransforms did: for every
  // .clickable-word carrying a data-cupitor-orig snapshot, restore
  // the original text and strip the transform decoration. A later
  // apply call re-populates everything.
  window.__cupitorRevertTextTransforms = function () {
    var spans = document.querySelectorAll('span.clickable-word[data-cupitor-orig]');
    for (var i = 0; i < spans.length; i++) {
      var s = spans[i];
      var orig = s.getAttribute('data-cupitor-orig') || '';
      s.textContent = orig;
      s.classList.remove('cupitor-xform');
      s.removeAttribute('data-cupitor-orig');
      s.removeAttribute('title');
    }
  };

  // ---------- CSS injection ----------

  function ensureStyles() {
    if (document.getElementById('__cupitor_st_styles')) return;
    var style = document.createElement('style');
    style.id = '__cupitor_st_styles';
    // body.cupitor-filter-active dims ALL inherited text colour so
    // short words (utils.js skips ≤2-char words) + punctuation +
    // whitespace also fade. Kept .clickable-word spans get `color:
    // initial` to restore the page's default text colour, so the
    // existing .cupitor-fade opacity rule alone differentiates kept
    // from dimmed within the wrapped set.
    style.textContent =
      '.cupitor-temp-highlight{background-color:rgba(255,235,59,0.35) !important;}' +
      '.cupitor-tagged{box-decoration-break:clone;-webkit-box-decoration-break:clone;}' +
      '.cupitor-fade{opacity:0.25 !important;transition:opacity 0.15s;}' +
      '.cupitor-tag-dot::before{content:"\\2022 ";font-weight:bold;}' +
      '.cupitor-masked-out{display:none !important;}' +
      '.cupitor-mask{display:inline;padding:0 2px;border-radius:2px;' +
      'background:rgba(0,0,0,0.05);font-style:italic;cursor:pointer;}' +
      // Transformed text: dotted underline in the accent hue so it reads
      // "this differs from the source". Hovering shows the original.
      '.cupitor-xform{border-bottom:1px dotted rgba(0,120,215,0.75);}' +
      'body.cupitor-filter-active{color:rgba(0,0,0,0.30) !important;}' +
      'body.cupitor-filter-active .clickable-word,' +
      'body.cupitor-filter-active .cupitor-mask{color:initial !important;}';
    (document.head || document.documentElement).appendChild(style);
  }

  // ---------- Multi-stamp helpers ----------

  function spanDbids(el) {
    var s = el.getAttribute('data-cupitor-dbid');
    if (!s) return [];
    return s.split(',').map(function(x){return parseInt(x,10);})
      .filter(function(n){return !isNaN(n);});
  }
  function setSpanDbids(el, ids) {
    if (!ids.length) el.removeAttribute('data-cupitor-dbid');
    else el.setAttribute('data-cupitor-dbid', ids.join(','));
  }
  function addDbidToSpan(el, id) {
    var ids = spanDbids(el);
    if (ids.indexOf(id) >= 0) return;
    ids.push(id);
    setSpanDbids(el, ids);
  }
  function removeDbidFromSpan(el, id) {
    var ids = spanDbids(el).filter(function(x){return x !== id;});
    setSpanDbids(el, ids);
  }
  // Recompute a single span's tagids CSV / mask attr / background color
  // from the union of groups currently covering it. Called after any
  // add/remove of a dbid on a span.
  function recomputeSpanAttrs(el) {
    var ids = spanDbids(el);
    if (!ids.length) {
      el.removeAttribute('data-cupitor-tagids');
      el.removeAttribute('data-cupitor-mask');
      el.classList.remove('cupitor-tagged');
      el.style.backgroundColor = '';
      el.removeAttribute('data-cupitor-extra-tags');
      return;
    }
    var tagBag = {};
    // Shortest-wins for paint: a short overlay (e.g. spans 3..4) on top
    // of a longer group (1..8) should visually pop — like CSS
    // specificity. The longer group still paints its exclusive spans.
    var paintGroup = null;
    var bestMaskGroup = null;
    for (var i = 0; i < ids.length; i++) {
      var g = tagSets[ids[i]];
      if (!g) continue;
      for (var j = 0; j < (g.tagIds || []).length; j++) tagBag[g.tagIds[j]] = 1;
      if (g.colors && g.colors.length) {
        var pLen = (g.spans || []).length;
        if (!paintGroup || (paintGroup.spans || []).length > pLen) {
          paintGroup = g;
        }
      }
      if (g.mask) {
        var mLen = (g.spans || []).length;
        if (!bestMaskGroup || (bestMaskGroup.spans || []).length < mLen) {
          bestMaskGroup = g;
        }
      }
    }
    var paintColors = paintGroup ? paintGroup.colors : null;
    var tagArr = Object.keys(tagBag);
    if (tagArr.length) el.setAttribute('data-cupitor-tagids', tagArr.join(','));
    else el.removeAttribute('data-cupitor-tagids');
    if (bestMaskGroup) el.setAttribute('data-cupitor-mask', bestMaskGroup.mask);
    else el.removeAttribute('data-cupitor-mask');
    paintSpanWithTagColors(el, paintColors || []);
  }
  function registerTagSet(id, tagIds, colors, spans, mask) {
    tagSets[id] = {
      id: id,
      tagIds: tagIds || [],
      colors: colors || [],
      spans: spans || [],
      mask: mask || '',
    };
  }
  function stampGroup(id) {
    var g = tagSets[id];
    if (!g) return;
    for (var i = 0; i < g.spans.length; i++) {
      var el = g.spans[i];
      if (!el) continue;
      addDbidToSpan(el, id);
      recomputeSpanAttrs(el);
    }
  }
  function unstampGroup(id) {
    var g = tagSets[id];
    if (!g) return;
    for (var i = 0; i < g.spans.length; i++) {
      var el = g.spans[i];
      if (!el) continue;
      removeDbidFromSpan(el, id);
      recomputeSpanAttrs(el);
    }
    delete tagSets[id];
  }
  // Longest-wins: among the groups on this span that have a mask, pick
  // the dbid whose range covers the most spans. When a filter is active
  // (filterTagIds non-null), groups whose tagIds don't intersect the
  // filter are skipped — so masking respects "show only these tags"
  // semantics. Returns null when no eligible group carries a mask.
  function winningMaskDbid(el) {
    var ids = spanDbids(el);
    var bestId = null, bestLen = -1;
    for (var i = 0; i < ids.length; i++) {
      var g = tagSets[ids[i]];
      if (!g || !g.mask) continue;
      if (filterTagIds) {
        var anyMatch = false;
        for (var t = 0; t < (g.tagIds || []).length; t++) {
          if (filterTagIds[g.tagIds[t]]) { anyMatch = true; break; }
        }
        if (!anyMatch) continue;
      }
      var len = (g.spans || []).length;
      if (len > bestLen) { bestLen = len; bestId = ids[i]; }
    }
    return bestId;
  }

  // ---------- Block + segmentation helpers ----------

  var BLOCK_TAGS = {
    P:1, DIV:1, LI:1, BLOCKQUOTE:1, SECTION:1, ARTICLE:1, ASIDE:1,
    HEADER:1, FOOTER:1, NAV:1, MAIN:1, FIGURE:1, FIGCAPTION:1, TD:1, TH:1,
    DD:1, DT:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1, PRE:1
  };

  function nearestBlock(el) {
    var n = el;
    while (n && n !== document.body) {
      if (n.nodeType === 1 && BLOCK_TAGS[n.tagName]) return n;
      n = n.parentNode;
    }
    return el.parentElement || document.body;
  }

  // Returns the text of the block + an array of word-span entries
  // [{span, start, end}] giving each clickable-word's offset range
  // inside the block's textContent.
  function blockWordIndex(block) {
    var text = '';
    var entries = [];
    function walk(node) {
      if (node.nodeType === 3) {
        text += node.nodeValue;
      } else if (node.nodeType === 1) {
        if (node.tagName === 'SPAN' && node.classList &&
            node.classList.contains('clickable-word')) {
          var start = text.length;
          // Use the ORIGINAL (pre-transform) word text when a rule has
          // rewritten this span. This keeps blockWordIndex + sentence
          // segmentation + rehydrate fingerprints agreeing with what
          // the DB has stored, independent of any display transforms.
          var inner = originalTextOf(node);
          text += inner;
          entries.push({ span: node, start: start, end: start + inner.length });
        } else {
          for (var i = 0; i < node.childNodes.length; i++) walk(node.childNodes[i]);
        }
      }
    }
    for (var i = 0; i < block.childNodes.length; i++) walk(block.childNodes[i]);
    return { text: text, entries: entries };
  }

  function segmentSentences(text) {
    var raw;
    try {
      var seg = new Intl.Segmenter(undefined, { granularity: 'sentence' });
      raw = [];
      var iter = seg.segment(text);
      for (var s of iter) {
        raw.push({ start: s.index, end: s.index + s.segment.length, segment: s.segment });
      }
    } catch (e) {
      // Fallback: regex split on sentence terminators followed by whitespace.
      raw = [];
      var re = /[^.!?؟。]+[.!?؟。]+\s*|[^.!?؟。]+$/g;
      var m;
      while ((m = re.exec(text)) !== null) {
        raw.push({ start: m.index, end: m.index + m[0].length, segment: m[0] });
        if (re.lastIndex === m.index) re.lastIndex++;
      }
      if (!raw.length && text) raw.push({ start: 0, end: text.length, segment: text });
    }
    // Merge fragments that don't end at a real sentence terminator
    // (.!? + CJK equivalents). Intl.Segmenter follows UAX#29 sentence
    // boundary rules, which include paragraph separators (LF, CR,
    // PSEP). On line-wrapping SPAs like litteraturbanken the prose
    // text node contains an explicit \n between each rendered line,
    // so the segmenter ends a segment at every \n — producing one
    // fragment per LINE instead of per sentence. Merging adjacent
    // fragments until a real terminator restores sentence-level
    // chunking without breaking pages where each sentence DOES end
    // in punctuation.
    return mergeFragmentsAtRealTerminators(raw, text);
  }

  function mergeFragmentsAtRealTerminators(raw, fullText) {
    var out = [];
    var cur = null;
    var termRe = /[.!?؟。！？]/;
    for (var i = 0; i < raw.length; i++) {
      var s = raw[i];
      if (cur === null) cur = { start: s.start, end: s.end };
      else cur.end = s.end;
      var trimmed = s.segment.replace(/\s+$/, '');
      var lastChar = trimmed.charAt(trimmed.length - 1);
      var isLast = i === raw.length - 1;
      if (termRe.test(lastChar) || isLast) {
        out.push({
          start: cur.start,
          end: cur.end,
          segment: fullText.substring(cur.start, cur.end),
        });
        cur = null;
      }
    }
    return out;
  }

  // ---------- _fp (must match db.dart) ----------

  function fpNormalize(s) {
    var out = (s || '').toLowerCase();
    out = out.replace(/[.,!?;:'"()\[\]{}\-—–…]/g, '');
    out = out.replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
    return out;
  }

  async function _fp(s) {
    var norm = fpNormalize(s);
    if (!norm) return '';
    try {
      var enc = new TextEncoder().encode(norm);
      var buf = await crypto.subtle.digest('SHA-1', enc);
      var bytes = new Uint8Array(buf);
      var hex = '';
      for (var i = 0; i < bytes.length; i++) {
        var h = bytes[i].toString(16);
        if (h.length === 1) hex += '0';
        hex += h;
      }
      return hex.substring(0, 8);
    } catch (e) {
      return '';
    }
  }

  // ---------- Capture ----------

  // Called by utils.js when capture mode is ON and a word is tapped.
  window.__cupitorOnWordTap = async function (span) {
    if (!span) return;
    ensureStyles();
    var block = segmentationScope === 'document'
      ? document.body
      : nearestBlock(span);
    var idx = blockWordIndex(block);
    if (!idx.entries.length) return;
    // Find a representative offset for the tapped span (middle of its range).
    var tappedEntry = null;
    for (var i = 0; i < idx.entries.length; i++) {
      if (idx.entries[i].span === span) { tappedEntry = idx.entries[i]; break; }
    }
    if (!tappedEntry) return;
    var pivot = (tappedEntry.start + tappedEntry.end) >> 1;
    var sents = segmentSentences(idx.text);
    if (!sents.length) return;
    var hit = 0;
    for (var s = 0; s < sents.length; s++) {
      if (pivot >= sents[s].start && pivot < sents[s].end) { hit = s; break; }
      if (pivot < sents[s].start) { hit = Math.max(0, s - 1); break; }
      if (s === sents.length - 1) hit = s;
    }
    var sid = nextSid();
    captureState[sid] = {
      block: block,
      idx: idx,
      sents: sents,
      from: hit,
      to: hit,
    };
    applyTempHighlight(sid);
    var payload = await buildCapturePayload(sid, 'capture');
    if (window.SentenceTagHandler) {
      window.SentenceTagHandler.postMessage(JSON.stringify(payload));
    }
  };

  // Apply the temporary yellow highlight to every word-span whose
  // offset range overlaps the current [from..to] sentence range.
  function applyTempHighlight(sid) {
    var st = captureState[sid];
    if (!st) return;
    var lo = st.sents[st.from].start;
    var hi = st.sents[st.to].end;
    var entries = st.idx.entries;
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i];
      if (e.end > lo && e.start < hi) {
        e.span.classList.add('cupitor-temp-highlight');
        e.span.setAttribute('data-cupitor-sent', sid);
      } else if (e.span.getAttribute('data-cupitor-sent') === sid) {
        // Was part of this capture before an extend pushed past it (unlikely
        // but happens if user reverses direction repeatedly).
        e.span.classList.remove('cupitor-temp-highlight');
        e.span.removeAttribute('data-cupitor-sent');
      }
    }
  }

  async function buildCapturePayload(sid, op) {
    var st = captureState[sid];
    if (!st) return null;
    var text = sliceSent(st, st.from, st.to);
    var prevText = st.from > 0 ? st.sents[st.from - 1].segment : '';
    var nextText = st.to < st.sents.length - 1 ? st.sents[st.to + 1].segment : '';
    var prevFp = prevText ? await _fp(prevText) : '';
    var nextFp = nextText ? await _fp(nextText) : '';
    return {
      op: op,
      sentenceId: sid,
      text: text,
      prev: prevText,
      next: nextText,
      prevFp: prevFp,
      nextFp: nextFp,
    };
  }

  function sliceSent(st, from, to) {
    var lo = st.sents[from].start;
    var hi = st.sents[to].end;
    return st.idx.text.substring(lo, hi).replace(/\s+/g, ' ').trim();
  }

  // Dart asks JS to extend the current capture range by one sentence
  // in 'prev' or 'next' direction (within the same block).
  window.__cupitorRequestExtend = async function (sid, direction) {
    var st = captureState[sid];
    if (!st) return;
    var atBoundary = false;
    if (direction === 'prev') {
      if (st.from > 0) { st.from -= 1; } else atBoundary = true;
    } else if (direction === 'next') {
      if (st.to < st.sents.length - 1) { st.to += 1; } else atBoundary = true;
    } else if (direction === 'trimStart') {
      if (st.to > st.from) { st.from += 1; } else atBoundary = true;
    } else if (direction === 'trimEnd') {
      if (st.to > st.from) { st.to -= 1; } else atBoundary = true;
    }
    if (atBoundary) {
      if (window.SentenceTagHandler) {
        window.SentenceTagHandler.postMessage(JSON.stringify({
          op: 'extend',
          sentenceId: sid,
          direction: direction,
          text: null,
        }));
      }
      return;
    }
    applyTempHighlight(sid);
    var payload = await buildCapturePayload(sid, 'extend');
    payload.direction = direction;
    if (window.SentenceTagHandler) {
      window.SentenceTagHandler.postMessage(JSON.stringify(payload));
    }
  };

  // Dart says: cancel. Clear the temp highlight; capture state can be
  // discarded.
  window.__cupitorClearTempHighlight = function (sid) {
    if (sid) {
      clearOne(sid);
    } else {
      Object.keys(captureState).forEach(clearOne);
    }
  };

  function clearOne(sid) {
    var st = captureState[sid];
    if (!st) return;
    var spans = document.querySelectorAll('[data-cupitor-sent="' + sid + '"]');
    for (var i = 0; i < spans.length; i++) {
      spans[i].classList.remove('cupitor-temp-highlight');
      // Don't drop the data attr — if the user re-opens the popup later
      // we want a way back. But on cancel we DO drop, since there's no
      // sentence in the DB yet.
      spans[i].removeAttribute('data-cupitor-sent');
    }
    delete captureState[sid];
  }

  // Dart says: Save succeeded. Paint the permanent highlight using
  // tagColors[0] as the background. Also stamp data-cupitor-dbid /
  // data-cupitor-tagids / data-cupitor-mask on every span so the
  // filter and the mask toggle can act on this sentence without
  // depending on rehydrate's text-match. [mask] is optional; passing
  // undefined or '' clears the existing data-cupitor-mask.
  window.__cupitorCommitTags = function (sid, dbid, tagColorsJson, tagIdsCsv, mask) {
    var tagColors;
    try { tagColors = JSON.parse(tagColorsJson); } catch (_) { tagColors = []; }
    committedTags[sid] = tagColors;
    var spans = Array.prototype.slice.call(
      document.querySelectorAll('[data-cupitor-sent="' + sid + '"]')
    );
    for (var i = 0; i < spans.length; i++) {
      spans[i].classList.remove('cupitor-temp-highlight');
    }
    if (dbid == null || String(dbid) === '') {
      delete captureState[sid];
      return;
    }
    var id = parseInt(dbid, 10);
    var tagIds = (tagIdsCsv == null ? '' : String(tagIdsCsv))
      .split(',').map(function (x) { return parseInt(x, 10); })
      .filter(function (n) { return !isNaN(n); });
    // Re-edit of an existing group: tear down its old stamp first so
    // shared spans don't keep stale tag/mask state from the prior set.
    if (tagSets[id]) unstampGroup(id);
    registerTagSet(id, tagIds, tagColors, spans, mask || '');
    stampGroup(id);
    if (masksVisible) refreshAllMaskInjections();
    delete captureState[sid];
  };

  function paintSpanWithTagColors(span, tagColors) {
    if (!tagColors || !tagColors.length) {
      span.style.backgroundColor = '';
      span.classList.remove('cupitor-tagged');
      return;
    }
    var primary = hexToRgba(tagColors[0], 0.30);
    span.style.backgroundColor = primary;
    span.classList.add('cupitor-tagged');
    // Extra-tag dots: prepend the first span only — that's the
    // visual handled via span.dataset.cupitorTagDots which we pick
    // up below. (We don't try to identify "first span of sentence"
    // here; rehydrate does that explicitly.)
    if (tagColors.length > 1) {
      span.setAttribute('data-cupitor-extra-tags', String(tagColors.length - 1));
    }
  }

  function hexToRgba(hex, alpha) {
    var h = (hex || '').replace('#', '');
    if (h.length === 3) h = h.split('').map(function (c) { return c + c; }).join('');
    if (h.length !== 6) return 'rgba(255,235,59,' + alpha + ')';
    var r = parseInt(h.substring(0, 2), 16);
    var g = parseInt(h.substring(2, 4), 16);
    var b = parseInt(h.substring(4, 6), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
  }

  // ---------- Rehydrate (page-load) ----------

  // SPA pages (Angular, React-router, etc.) finish loading the shell
  // long before content is in the DOM. The first applyTags pass often
  // misses everything; record unmatched and retry as the DOM grows.
  var rehydratePending = [];
  var rehydrateObserver = null;
  var rehydrateRetryTimer = null;
  var rehydrateStopTimer = null;
  var REHYDRATE_DEBOUNCE_MS = 250;
  var REHYDRATE_GIVE_UP_MS = 60000;

  // Dart pushes the full snapshot of tagged sentences for the current
  // page after onPageFinished. We text-search the DOM for each and
  // paint permanent highlights. Stash the snapshot for the filter.
  window.__cupitorApplyTags = function (json) {
    ensureStyles();
    var list;
    try { list = JSON.parse(json); } catch (_) { list = []; }
    rehydrated = list || [];
    // Hard reset: drop mask injections + every span's stamp state so a
    // fresh snapshot starts from a clean canvas.
    clearAllMaskInjections();
    tagSets = {};
    document.querySelectorAll('span.clickable-word[data-cupitor-dbid]').forEach(function (el) {
      el.classList.remove('cupitor-tagged');
      el.style.backgroundColor = '';
      el.removeAttribute('data-cupitor-extra-tags');
      el.removeAttribute('data-cupitor-sent');
      el.removeAttribute('data-cupitor-dbid');
      el.removeAttribute('data-cupitor-tagids');
      el.removeAttribute('data-cupitor-mask');
    });
    var matched = 0;
    var pending = [];
    for (var i = 0; i < rehydrated.length; i++) {
      if (paintRehydratedSentence(rehydrated[i])) matched++;
      else pending.push(rehydrated[i]);
    }
    if (masksVisible) refreshAllMaskInjections();
    if (window.SnippetLogChannel) {
      window.SnippetLogChannel.postMessage(
        '[tagging] rehydrate matched=' + matched + '/' + rehydrated.length
      );
    }
    rehydratePending = pending;
    stopRehydrateObserver();
    if (pending.length > 0 || filterTagIds) startRehydrateObserver();
    // If we matched at least one and a filter is already active, the
    // first applyFilter pass ran on an empty DOM — re-fade now.
    if (matched > 0 && filterTagIds) refreshFilterFade();
  };

  function startRehydrateObserver() {
    if (rehydrateObserver || !document.body) return;
    rehydrateObserver = new MutationObserver(function () {
      if (rehydrateRetryTimer !== null) clearTimeout(rehydrateRetryTimer);
      rehydrateRetryTimer = setTimeout(retryRehydrate, REHYDRATE_DEBOUNCE_MS);
    });
    rehydrateObserver.observe(document.body, {childList: true, subtree: true});
    rehydrateStopTimer = setTimeout(stopRehydrateObserver, REHYDRATE_GIVE_UP_MS);
  }

  function stopRehydrateObserver() {
    if (rehydrateObserver) { rehydrateObserver.disconnect(); rehydrateObserver = null; }
    if (rehydrateRetryTimer !== null) { clearTimeout(rehydrateRetryTimer); rehydrateRetryTimer = null; }
    if (rehydrateStopTimer !== null) { clearTimeout(rehydrateStopTimer); rehydrateStopTimer = null; }
  }

  function retryRehydrate() {
    rehydrateRetryTimer = null;
    var newlyMatched = 0;
    if (rehydratePending.length) {
      var still = [];
      for (var i = 0; i < rehydratePending.length; i++) {
        if (paintRehydratedSentence(rehydratePending[i])) newlyMatched++;
        else still.push(rehydratePending[i]);
      }
      rehydratePending = still;
      if (newlyMatched > 0) {
        if (masksVisible) refreshAllMaskInjections();
        if (window.SnippetLogChannel) {
          window.SnippetLogChannel.postMessage(
            '[tagging] rehydrate retry +' + newlyMatched + ' (pending=' + rehydratePending.length + ')'
          );
        }
      }
    }
    // Whether or not we matched anything new, if a filter is active we
    // need to fade any .clickable-word spans that the SPA just added.
    if (filterTagIds) refreshFilterFade();
    if (!rehydratePending.length && !filterTagIds) stopRehydrateObserver();
  }

  function refreshFilterFade() {
    if (!filterTagIds) return;
    var spans = document.querySelectorAll('span.clickable-word, .cupitor-mask');
    for (var j = 0; j < spans.length; j++) {
      var tagsAttr = spans[j].getAttribute('data-cupitor-tagids');
      var keep = false;
      if (tagsAttr) {
        var arr = tagsAttr.split(',');
        for (var m = 0; m < arr.length; m++) {
          var n = parseInt(arr[m], 10);
          if (!isNaN(n) && filterTagIds[n]) { keep = true; break; }
        }
      }
      if (keep) spans[j].classList.remove('cupitor-fade');
      else spans[j].classList.add('cupitor-fade');
    }
  }

  function paintRehydratedSentence(rec) {
    var sid = 's_db_' + rec.id;
    // Mirror the capture-time scope. 'document' uses body as the single
    // search root so sentences spanning many per-line wrappers are
    // findable; 'block' iterates conventional block elements.
    var blocks = segmentationScope === 'document'
      ? [document.body]
      : document.querySelectorAll(
          'p,div,li,blockquote,section,article,td,th,dd,dt,h1,h2,h3,h4,h5,h6,pre'
        );
    for (var b = 0; b < blocks.length; b++) {
      var idx = blockWordIndex(blocks[b]);
      if (!idx.entries.length) continue;
      var sents = segmentSentences(idx.text);
      for (var s = 0; s < sents.length; s++) {
        if (!normEq(sents[s].segment, rec.text)) continue;
        var spans = collectSpansInRange(idx, sents[s].start, sents[s].end);
        if (!spans.length) continue;
        for (var i = 0; i < spans.length; i++) {
          // Keep data-cupitor-sent for commit-flow lookup. Overlapping
          // captures share the bare element identity; the per-group
          // dbid CSV (set via stampGroup below) is what filter and
          // mask logic consult.
          spans[i].setAttribute('data-cupitor-sent', sid);
        }
        registerTagSet(rec.id, rec.tagIds || [], rec.tagColors || [], spans, rec.mask || '');
        stampGroup(rec.id);
        return true;
      }
    }
    return false;
  }

  function collectSpansInRange(idx, lo, hi) {
    var out = [];
    for (var i = 0; i < idx.entries.length; i++) {
      var e = idx.entries[i];
      if (e.end > lo && e.start < hi) out.push(e.span);
    }
    return out;
  }

  function normEq(a, b) {
    return fpNormalize(a) === fpNormalize(b);
  }

  // ---------- Filter ----------

  // Dart sends a JSON array of tag IDs to filter by. Empty array clears
  // the filter. Faded sentences keep their click-look-up handler so the
  // user can still interact. The keep decision reads
  // `data-cupitor-tagids` directly off each .clickable-word span (set
  // at commit / rehydrate) — independent of the `rehydrated` cache, so
  // a freshly-saved sentence is visible even before any reload.
  // Wipe ALL tag-paint, dbid stamps, mask injections, filter state.
  // Used by the Dart side when switching profiles — we re-rehydrate
  // immediately after with the new profile's records.
  window.__cupitorClearAllTags = function () {
    rehydrated = [];
    rehydratePending = [];
    stopRehydrateObserver();
    filterTagIds = null;
    tagSets = {};
    clearAllMaskInjections();
    document.body && document.body.classList.remove('cupitor-filter-active');
    document.querySelectorAll('span.clickable-word[data-cupitor-dbid]').forEach(function (el) {
      el.classList.remove('cupitor-tagged');
      el.classList.remove('cupitor-fade');
      el.classList.remove('cupitor-masked-out');
      el.style.backgroundColor = '';
      el.removeAttribute('data-cupitor-dbid');
      el.removeAttribute('data-cupitor-tagids');
      el.removeAttribute('data-cupitor-mask');
      el.removeAttribute('data-cupitor-sent');
      el.removeAttribute('data-cupitor-extra-tags');
    });
    // Drop fade from spans that the filter had previously dimmed.
    document.querySelectorAll('.cupitor-fade').forEach(function (el) {
      el.classList.remove('cupitor-fade');
    });
  };

  // Dart calls this after a record is deleted in the DB so we drop just
  // that group's stamp (and any masks it owned) without re-rehydrating.
  window.__cupitorUnstampGroup = function (dbid) {
    var id = parseInt(dbid, 10);
    if (isNaN(id)) return;
    if (tagSets[id]) {
      unstampGroup(id);
      if (masksVisible) refreshAllMaskInjections();
    }
  };

  window.__cupitorApplyFilter = function (tagIdsJson) {
    ensureStyles();
    var ids;
    try { ids = JSON.parse(tagIdsJson); } catch (_) { ids = []; }
    if (!ids.length) {
      filterTagIds = null;
      var spans = document.querySelectorAll('span.clickable-word, .cupitor-mask');
      for (var i = 0; i < spans.length; i++) {
        spans[i].classList.remove('cupitor-fade');
      }
      document.body && document.body.classList.remove('cupitor-filter-active');
      // Re-layout masks now that filter no longer scopes longest-wins.
      if (masksVisible) refreshAllMaskInjections();
      if (!rehydratePending.length) stopRehydrateObserver();
      return;
    }
    document.body && document.body.classList.add('cupitor-filter-active');
    filterTagIds = {};
    for (var i = 0; i < ids.length; i++) filterTagIds[ids[i]] = 1;
    // Re-layout masks so filtered-out groups no longer cover spans
    // owned by a filter-matching shorter group.
    if (masksVisible) refreshAllMaskInjections();
    refreshFilterFade();
    // SPAs may stream content in well after this call; keep the
    // observer alive to re-fade newly-added .clickable-word spans.
    startRehydrateObserver();
  };

  // ---------- Capture-mode flag ----------

  window.__cupitorSetCaptureMode = function (active) {
    window.__cupitorCaptureMode = !!active;
    if (!active) {
      // Drop any in-flight capture highlights.
      Object.keys(captureState).forEach(clearOne);
    }
  };

  // 'block' or 'document'. See [segmentationScope] above for context.
  window.__cupitorSetSegmentationScope = function (scope) {
    segmentationScope = scope === 'document' ? 'document' : 'block';
    if (window.SnippetLogChannel) {
      window.SnippetLogChannel.postMessage('[tagging] segmentation scope = ' + segmentationScope);
    }
  };

  // ---------- Masks (replacement text) ----------

  function clearAllMaskInjections() {
    Object.keys(maskInjections).forEach(function (key) {
      var info = maskInjections[key];
      if (info && info.el && info.el.parentNode) info.el.parentNode.removeChild(info.el);
    });
    maskInjections = {};
    document.querySelectorAll('span.clickable-word.cupitor-masked-out')
      .forEach(function (el) { el.classList.remove('cupitor-masked-out'); });
  }

  // Walk all .clickable-word spans in DOM order, group consecutive ones
  // by their winning mask group (longest-wins per span), and inject one
  // .cupitor-mask span per contiguous run. Groups whose mask loses to a
  // longer overlapping group on every span never get injected.
  function refreshAllMaskInjections() {
    clearAllMaskInjections();
    if (!masksVisible) return;
    var all = document.querySelectorAll('span.clickable-word');
    var runStart = -1, runDbid = null;
    function injectRun(startIdx, endIdx, winningDbid) {
      if (startIdx < 0 || winningDbid == null) return;
      var g = tagSets[winningDbid];
      if (!g || !g.mask) return;
      var firstEl = all[startIdx], lastEl = all[endIdx];
      var maskEl = document.createElement('span');
      maskEl.className = 'cupitor-mask';
      maskEl.setAttribute('data-cupitor-dbid', String(winningDbid));
      var tagIds = firstEl.getAttribute('data-cupitor-tagids') || '';
      if (tagIds) maskEl.setAttribute('data-cupitor-tagids', tagIds);
      var bg = firstEl.style.backgroundColor;
      if (bg) maskEl.style.backgroundColor = bg;
      maskEl.textContent = g.mask;
      lastEl.parentNode.insertBefore(maskEl, lastEl.nextSibling);
      for (var i = startIdx; i <= endIdx; i++) {
        all[i].classList.add('cupitor-masked-out');
      }
      maskInjections[winningDbid + ':' + startIdx + '-' + endIdx] = {
        el: maskEl, dbid: winningDbid,
      };
    }
    for (var i = 0; i < all.length; i++) {
      var w = winningMaskDbid(all[i]);
      if (w == null) {
        if (runStart >= 0) { injectRun(runStart, i - 1, runDbid); runStart = -1; runDbid = null; }
        continue;
      }
      if (w !== runDbid) {
        if (runStart >= 0) injectRun(runStart, i - 1, runDbid);
        runStart = i; runDbid = w;
      }
    }
    if (runStart >= 0) injectRun(runStart, all.length - 1, runDbid);
  }

  window.__cupitorSetMasksVisible = function (active) {
    ensureStyles();
    masksVisible = !!active;
    refreshAllMaskInjections();
  };

  // ---------- Long-press → edit request ----------

  // Detect a sustained press on any element carrying data-cupitor-dbid
  // (a tagged span OR the injected mask element) and post an edit
  // request so Dart can re-open the capture sheet pre-populated.
  // 500 ms feels right; tweak if your hardware needs more.
  var LP_MS = 500;
  var lpTimer = null;
  var lpTarget = null;
  var lpFired = false;
  function lpStart(ev) {
    var src = ev.target && ev.target.closest && ev.target.closest('[data-cupitor-dbid]');
    if (!src) return;
    lpTarget = src;
    lpFired = false;
    clearTimeout(lpTimer);
    lpTimer = setTimeout(function () {
      lpFired = true;
      var ids = spanDbids(lpTarget);
      if (!ids.length) return;
      if (!window.SentenceTagHandler) return;
      if (ids.length === 1) {
        window.SentenceTagHandler.postMessage(JSON.stringify({
          op: 'editRequest',
          dbid: ids[0],
        }));
      } else {
        // Span owned by multiple groups: route through the chooser sheet
        // so the user can pick which one to edit.
        window.SentenceTagHandler.postMessage(JSON.stringify({
          op: 'taggedChoice',
          dbids: ids,
        }));
      }
    }, LP_MS);
  }
  function lpEnd() {
    clearTimeout(lpTimer);
    lpTimer = null;
    lpTarget = null;
  }
  document.addEventListener('touchstart', lpStart, { passive: true });
  document.addEventListener('touchend', lpEnd, { passive: true });
  document.addEventListener('touchcancel', lpEnd, { passive: true });
  document.addEventListener('touchmove', lpEnd, { passive: true });
  document.addEventListener('mousedown', lpStart);
  document.addEventListener('mouseup', lpEnd);
  document.addEventListener('mouseleave', lpEnd);
  // If the long-press fired, swallow the subsequent click so the
  // existing word-tap handler doesn't also open the lookup dialog.
  document.addEventListener('click', function (e) {
    if (lpFired) {
      e.preventDefault();
      e.stopPropagation();
      lpFired = false;
    }
  }, true);

  // ---------- Self-test (debug) ----------

  // The Dart side calls db.fpSelfTest() on launch and forwards results
  // via SnippetLogChannel. We compute the same here so a mismatch
  // becomes a single grep-able log line.
  (async function selfTest() {
    var cases = {
      'empty': '',
      'single': 'Hello',
      'with_punct': 'Hello, World!',
      'whitespace_run': '  multiple   spaces\there',
      'mixed_case': 'CamelCase WORDS',
      'em_dash': 'one — two',
      'en_dash': 'one – two',
      'ellipsis': 'so…',
      'quotes': '"quoted" and \'single\'',
      'numbers': 'Page 42 of 100',
    };
    var keys = Object.keys(cases);
    var out = {};
    for (var i = 0; i < keys.length; i++) {
      out[keys[i]] = await _fp(cases[keys[i]]);
    }
    if (window.SnippetLogChannel) {
      window.SnippetLogChannel.postMessage(
        '[tagging] fp-selftest-js ' + JSON.stringify(out)
      );
    }
  })();

  // Announce ready so Dart can push state if it was waiting.
  if (window.SentenceFilterHandler) {
    window.SentenceFilterHandler.postMessage(JSON.stringify({ op: 'ready' }));
  }
})();
