(function() {
  const MAX_TEXT_LEN = 50000;        // skip text nodes longer than this (Intl.Segmenter cost)
  const CHUNK_BUDGET_MS = 4;          // hard cap on synchronous work per chunk
  const DEBOUNCE_MS = 600;            // wait after last mutation before flushing
  const MAX_LATENCY_MS = 3000;        // force flush even during continuous streaming
  const MAX_QUEUE_PER_FLUSH = 1500;   // bound collection work; rest picked up on next flush
  const YIELD_FALLBACK_MS = 16;       // ≈ one frame; leaves room for scroll/paint

  const SKIP_TAGS = new Set([
    'A', 'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'SVG',
    'CANVAS', 'CODE', 'PRE', 'BUTTON', 'SELECT', 'OPTION', 'VIDEO', 'AUDIO'
  ]);

  const now = () => (typeof performance !== 'undefined' && performance.now)
    ? performance.now() : Date.now();

  // Prefer requestIdleCallback so the browser runs us only when it has no
  // higher-priority work (scroll, input, paint). Fall back to a one-frame
  // setTimeout — NOT setTimeout(fn, 0), which can starve scroll on hot loops.
  const yieldToBrowser = window.requestIdleCallback
    ? (fn) => window.requestIdleCallback(fn, {timeout: 500})
    : (fn) => setTimeout(() => fn({timeRemaining: () => CHUNK_BUDGET_MS, didTimeout: false}), YIELD_FALLBACK_MS);

  function getWords(text) {
    if (typeof Intl !== 'undefined' && Intl.Segmenter) {
      const segmentor = new Intl.Segmenter([], {granularity: 'word'});
      return Array.from(segmentor.segment(text), ({segment, isWordLike}) =>
        ({text: segment, isWord: !!isWordLike})
      );
    } else {
      return text.split(/(\s+|[.,!?;:"'()\-])/g).filter(Boolean)
                 .map(s => ({text: s, isWord: /\w{3,}/.test(s)}));
    }
  }

  function shouldSkipParent(parent) {
    if (!parent || !parent.closest) return true;
    if (SKIP_TAGS.has(parent.nodeName)) return true;
    if (parent.isContentEditable) return true;  // inherits from ancestors
    // `closest` catches text nested deeper than the direct parent
    // (e.g. <a><span>foo</span></a> — parent is <span>, not <a>).
    if (parent.closest('a')) return true;
    if (parent.closest('.clickable-word')) return true;
    // Opt-out marker. Page scripts we control (snippet.js's subtitle sidebar,
    // the webapp) put this on chrome that is text but not reading material —
    // a cue's "12:34" timestamp, a status readout, a settings dialog. Without
    // it those get wrapped like prose and a tap on them opens a lookup for
    // "12". Honoured here rather than in the click handler so the spans are
    // never created in the first place.
    if (parent.closest('.cup-nolookup')) return true;
    return false;
  }

  function wrapTextNode(node) {
    if (!node.isConnected) return;
    const parent = node.parentNode;
    if (!parent) return;
    if (shouldSkipParent(parent)) return;
    const text = node.textContent;
    if (!text || text.length > MAX_TEXT_LEN || !text.trim()) return;
    const words = getWords(text);
    // Wrap every non-empty word (was: length > 2). The old threshold
    // skipped 1- and 2-char particles ("är", "av", "nu", "i", "I", "a"),
    // which left them as raw text nodes — the sentence-tagging filter
    // can't stamp those with data-cupitor-tagids, so a kept sentence
    // had visible "holes" where short words inherited the body-level
    // dim. Wrapping them costs one click-target per particle (clicking
    // "i" now opens a lookup); we accept that for filter completeness.
    let hasWord = false;
    for (let i = 0; i < words.length; i++) {
      if (words[i].isWord && words[i].text.trim().length > 0) { hasWord = true; break; }
    }
    if (!hasWord) return;
    const frag = document.createDocumentFragment();
    for (const {text: word, isWord} of words) {
      if (!isWord || !word.trim().length) {
        frag.appendChild(document.createTextNode(word));
      } else {
        const span = document.createElement('span');
        span.className = 'clickable-word';
        span.dataset.word = word;
        span.textContent = word;
        frag.appendChild(span);
      }
    }
    parent.replaceChild(frag, node);
  }

  function collectTextNodes(root, out) {
    if (!root || !root.isConnected) return;
    if (root.nodeType === Node.TEXT_NODE) {
      if (!shouldSkipParent(root.parentNode)) out.push(root);
      return;
    }
    if (root.nodeType !== Node.ELEMENT_NODE) return;
    if (SKIP_TAGS.has(root.nodeName)) return;
    if (root.classList && root.classList.contains('clickable-word')) return;
    // `closest`, not `contains`: the observer can hand us a node nested
    // inside an opted-out container, not just the container itself.
    if (root.closest && root.closest('.cup-nolookup')) return;
    if (root.isContentEditable) return;

    // Walk both elements and text nodes so FILTER_REJECT on an element
    // prunes its entire subtree (SHOW_TEXT alone still visits text inside
    // skipped containers just to reject them one-by-one).
    const tw = document.createTreeWalker(
      root,
      NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
      {
        acceptNode(n) {
          if (n.nodeType === Node.ELEMENT_NODE) {
            if (SKIP_TAGS.has(n.nodeName)) return NodeFilter.FILTER_REJECT;
            if (n.classList && n.classList.contains('clickable-word')) return NodeFilter.FILTER_REJECT;
            if (n.classList && n.classList.contains('cup-nolookup')) return NodeFilter.FILTER_REJECT;
            if (n.isContentEditable) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_SKIP;  // don't emit, but descend
          }
          const t = n.textContent;
          if (!t || !t.trim() || t.length > MAX_TEXT_LEN) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      }
    );
    let n;
    while ((n = tw.nextNode())) out.push(n);
  }

  // Persistent observer + chunked flusher. Guarded across script re-injection
  // (SPA navigations re-run this IIFE, but we only install once).
  function installObserver() {
    if (window._wordWrapObserverInstalled) return;
    window._wordWrapObserverInstalled = true;

    const pendingRoots = new Set();
    const OBSERVE_OPTS = { childList: true, subtree: true, characterData: true };
    let debounceTimer = null;
    let maxLatencyTimer = null;
    let processing = false;

    const observer = new MutationObserver((mutations) => {
      for (const m of mutations) {
        if (m.type === 'childList') {
          m.addedNodes.forEach((n) => {
            if (n.nodeType !== Node.ELEMENT_NODE && n.nodeType !== Node.TEXT_NODE) return;
            // Ignore our own output so the observer never feeds itself.
            if (n.nodeType === Node.ELEMENT_NODE
                && n.classList && n.classList.contains('clickable-word')) return;
            if (n.nodeType === Node.TEXT_NODE
                && n.parentNode && n.parentNode.closest
                && n.parentNode.closest('.clickable-word')) return;
            pendingRoots.add(n);
          });
        } else if (m.type === 'characterData') {
          const p = m.target.parentNode;
          if (!p) continue;
          if (p.closest && p.closest('.clickable-word')) continue;
          pendingRoots.add(p);
        }
      }
      scheduleFlush();
    });

    function scheduleFlush() {
      if (debounceTimer !== null) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(runFlush, DEBOUNCE_MS);
      // Guarantee a flush within MAX_LATENCY_MS even during continuous streaming
      // (where the debounce would otherwise keep resetting forever).
      if (maxLatencyTimer === null) {
        maxLatencyTimer = setTimeout(() => { maxLatencyTimer = null; runFlush(); }, MAX_LATENCY_MS);
      }
    }

    function runFlush() {
      if (debounceTimer !== null) { clearTimeout(debounceTimer); debounceTimer = null; }
      if (maxLatencyTimer !== null) { clearTimeout(maxLatencyTimer); maxLatencyTimer = null; }
      // Re-entrancy guard: if a chunked pass is already running, let it drain
      // any newly-added roots on its own final check.
      if (processing) return;
      // Skip expensive work when the user isn't looking.
      if (typeof document !== 'undefined' && document.hidden) { scheduleFlush(); return; }
      if (pendingRoots.size === 0) return;

      const roots = Array.from(pendingRoots);
      pendingRoots.clear();
      const queue = [];
      // Bound the synchronous collection phase: stop once we've got enough
      // text nodes to keep chunks busy for a while, OR when we've spent our
      // budget walking. Anything we didn't visit gets re-queued.
      const collectDeadline = now() + CHUNK_BUDGET_MS;
      let i = 0;
      for (; i < roots.length; i++) {
        collectTextNodes(roots[i], queue);
        if (queue.length >= MAX_QUEUE_PER_FLUSH) break;
        if (now() >= collectDeadline) break;
      }
      // Re-queue the roots we didn't get to, plus the body if we hit the cap
      // (more unwrapped text may still exist; wrapped ones are skipped cheaply).
      for (let j = i + 1; j < roots.length; j++) pendingRoots.add(roots[j]);
      if (queue.length >= MAX_QUEUE_PER_FLUSH) pendingRoots.add(document.body);
      if (queue.length === 0) {
        if (pendingRoots.size > 0) scheduleFlush();
        return;
      }

      processing = true;
      yieldToBrowser((deadline) => processChunk(queue, 0, deadline));
    }

    function processChunk(queue, start, deadline) {
      // Pause the observer for the synchronous chunk so our own replaceChild
      // calls don't feed back into pendingRoots.
      observer.disconnect();
      const hardDeadline = now() + CHUNK_BUDGET_MS;
      // Honour the idle-callback's remaining budget when present — the browser
      // tells us how much time it has before it needs the main thread back
      // (scroll, paint, input).
      const timeBudget = () => deadline && deadline.timeRemaining
        ? Math.min(deadline.timeRemaining(), CHUNK_BUDGET_MS)
        : CHUNK_BUDGET_MS;
      let i = start;
      while (i < queue.length) {
        wrapTextNode(queue[i]);
        i++;
        // Check both our own cap and the browser's hint so we bail fast if
        // scroll/input is waiting.
        if (now() >= hardDeadline) break;
        if (timeBudget() <= 0) break;
      }
      // Reconnect before yielding so external DOM mutations during the yield
      // (streaming tokens, new messages) are still observed.
      observer.observe(document.body, OBSERVE_OPTS);

      if (i < queue.length) {
        yieldToBrowser((d) => processChunk(queue, i, d));
      } else {
        processing = false;
        if (pendingRoots.size > 0) scheduleFlush();
      }
    }

    observer.observe(document.body, OBSERVE_OPTS);
    // Expose so the initial full-body wrap can reuse the chunked flusher.
    window._wordWrapEnqueue = (n) => { pendingRoots.add(n); };
    window._wordWrapFlush = scheduleFlush;
  }

  function wrapBody() {
    if (!document.body) return;
    if (window._wordWrapEnqueue && window._wordWrapFlush) {
      window._wordWrapEnqueue(document.body);
      window._wordWrapFlush();
    }
  }

  function main() {
    if (!window._wordWrapScheduled) {
      window._wordWrapScheduled = true;
      installObserver();
      // Short delay lets the initial DOM settle; the observer handles anything
      // that arrives later so this wait no longer needs to be conservative.
      setTimeout(wrapBody, 1500);
    }

    if (!window.myCustomerListenerAttached) {
      // Capture phase so SPA frameworks (React on chatgpt.com, etc.) that call
      // stopPropagation() on their own click handlers can't swallow us.
      document.addEventListener('click', (e) => {
        let t = e.target && e.target.closest && e.target.closest('.clickable-word');
        // The same opt-out the wrapper honours, applied to the tap itself.
        // The wrapper alone only promises "no new spans under here", which is
        // not enough for a container that gains the class after its words
        // were already wrapped — the subtitle sidebar does exactly that when
        // it enters select mode, where a tap must tick the line rather than
        // look a word up. Checked before capture mode too: a region that
        // opts out of lookups is not somewhere to tag a sentence either.
        if (t && t.closest('.cup-nolookup')) t = null;
        if (t) {
          try {
             // Sentence-tag capture mode: route to the tagging handler
             // and swallow the rest. Lookup is suppressed until the
             // user disarms capture (per the spec's "Conflict with
             // word-tap lookup" open edge).
             if (window.__cupitorCaptureMode && typeof window.__cupitorOnWordTap === 'function') {
               e.preventDefault();
               e.stopPropagation();
               window.__cupitorOnWordTap(t);
               return;
             }
             const base = (t.dataset && t.dataset.word) || t.textContent || '';
             const looked = joinHyphenatedWord(t);
             // Diagnostic — viewable via Tools → "View snippet logs".
             // Logs only when there's a dash anywhere near the tapped
             // word (the only case where a join is even possible), so
             // it doesn't spam the log on every routine lookup.
             try {
               logTapDiag(t, base, looked);
             } catch (_) {}
             CaptionHandler.postMessage(looked);
          } catch(e) {}
        }
      }, true);
      window.myCustomerListenerAttached = true;
    }
  }

  // Emits a one-line tap log when there's a dash in the immediate neighborhood
  // of the tapped word — captures the codepoint(s) of the dash so the user
  // can tell us what character the page is using if the join still misfires.
  // Routed through SnippetLogChannel (already registered on the main WebView)
  // so the existing "View snippet logs" UI surfaces it.
  function logTapDiag(span, base, looked) {
    if (!window.SnippetLogChannel || !window.SnippetLogChannel.postMessage) return;
    // Pull ~30 chars on each side from the block parent's textContent so
    // the log entry shows the actual neighborhood and any dash char(s).
    let blk = span.parentNode;
    while (blk && blk.nodeType === 1 && blk.tagName
           && !/^(P|LI|BLOCKQUOTE|DIV|H[1-6]|SECTION|ARTICLE|TD|TH|MAIN|ASIDE|HEADER|FOOTER|BODY)$/i.test(blk.tagName)) {
      blk = blk.parentNode;
    }
    if (!blk) return;
    const txt = (blk.textContent || '');
    const idx = txt.indexOf(base);
    if (idx < 0) return;
    const ctx = txt.substring(Math.max(0, idx - 30), Math.min(txt.length, idx + base.length + 30));
    // Only emit if the neighborhood contains any dash-like char — every
    // other tap is uninteresting and would just fill the log.
    if (!/[-‐‑‒–—−­]/.test(ctx)) return;
    // Hex of any dash chars near the word — so user can tell us "the dash
    // is U+2013" without needing DevTools.
    const dashCodes = [];
    for (const c of ctx) {
      if (/[-‐‑‒–—−­]/.test(c)) {
        const cp = c.codePointAt(0).toString(16).toUpperCase().padStart(4, '0');
        if (!dashCodes.includes(cp)) dashCodes.push(cp);
      }
    }
    const msg = 'word-tap base=' + JSON.stringify(base)
              + ' look=' + JSON.stringify(looked)
              + ' dash=[' + dashCodes.map(c => 'U+' + c).join(',') + ']'
              + ' ctx=' + JSON.stringify(ctx);
    try { window.SnippetLogChannel.postMessage('info|' + msg); } catch (_) {}
  }

  // Line-wrap hyphenation: when the page renders something as "trans-\nlation"
  // or "well- known" (two halves separated by a dash + whitespace), tapping
  // either half should look up the joined word.
  //
  // The earlier version walked only IMMEDIATE siblings of the clicked span,
  // which broke whenever the EPUB / web page nested halves inside different
  // wrappers (per-line spans, <i>, <em>, footnote markers — common on sites
  // like litteraturbanken.se that wrap each rendered line in its own span).
  // Instead we now read the block-parent's flattened textContent and locate
  // the clicked word's occurrence within it; the hyphen pattern lives in
  // that flat string regardless of wrapping. Disambiguation when the same
  // word appears multiple times in the block: count how many same-word
  // clickable-word spans precede the clicked one and pick that occurrence.
  function joinHyphenatedWord(span) {
    const base = (span.dataset && span.dataset.word) || span.textContent || '';
    if (!base) return '';
    // Walk up to a sensible block-ish parent. `BODY` is the failsafe — a
    // text run with no <p>/<div>/<li> ancestor still gets joined.
    let blk = span.parentNode;
    while (blk && blk.nodeType === 1
           && blk.tagName
           && !/^(P|LI|BLOCKQUOTE|DIV|H[1-6]|SECTION|ARTICLE|TD|TH|MAIN|ASIDE|HEADER|FOOTER|BODY)$/i.test(blk.tagName)) {
      blk = blk.parentNode;
    }
    if (!blk) return base;
    // Soft hyphens (U+00AD) are invisible line-break hints; drop them so
    // they don't end up in the lookup. Various Unicode hyphens are all
    // treated as line-break dashes for the join.
    const blockText = (blk.textContent || '').replace(/­/g, '');
    // Find the Nth occurrence of `base` in blockText, where N = number of
    // earlier `.clickable-word` spans with the same data-word inside the
    // block (DOM order). Lets us key the same string appearing 5 times.
    const all = blk.querySelectorAll('.clickable-word');
    let occurrence = 0;
    for (let i = 0; i < all.length; i++) {
      if (all[i] === span) break;
      if (((all[i].dataset && all[i].dataset.word) || '') === base) occurrence++;
    }
    let idx = -1;
    let cursor = 0;
    for (let k = 0; k <= occurrence; k++) {
      idx = blockText.indexOf(base, cursor);
      if (idx < 0) break;
      cursor = idx + base.length;
    }
    if (idx < 0) return base;
    const endIdx = idx + base.length;
    const WORD_RE = /[\p{L}\p{M}\p{N}'’-]/u;
    // Recognise every common dash codepoint as a hyphenation marker — the
    // page might use any of:
    //   U+002D HYPHEN-MINUS          (ASCII)
    //   U+2010 HYPHEN                (typographic, looks like a thin hyphen)
    //   U+2011 NON-BREAKING HYPHEN
    //   U+2012 FIGURE DASH
    //   U+2013 EN DASH               (European typography — common in
    //                                 older Swedish prints for compounds
    //                                 and line breaks)
    //   U+2014 EM DASH
    //   U+2212 MINUS SIGN
    // The "no whitespace before the dash" check below filters out the
    // false-positive case of en/em dashes acting as parenthetical
    // separators ("foo — bar") — those have whitespace on BOTH sides.
    const isDash = (c) =>
      c === '-' || c === '‐' || c === '‑' || c === '‒' ||
      c === '–' || c === '—' || c === '−';
    // Case A: tapped word ends with a dash (Intl.Segmenter kept it attached,
    // regex-fallback wrapper, or a non-Latin script split that included it).
    if (isDash(base[base.length - 1])) {
      let i = endIdx;
      while (i < blockText.length && /\s/.test(blockText[i])) i++;
      const ws = i;
      while (i < blockText.length && WORD_RE.test(blockText[i])) i++;
      if (i > ws) return base.slice(0, -1) + blockText.substring(ws, i);
    }
    // Case B: a dash sits IMMEDIATELY after our word (no whitespace between),
    // then optional whitespace, then the continuation word. The "no
    // whitespace before the dash" requirement is what distinguishes line-
    // break hyphenation ("foo-\nbar") from a parenthetical em dash
    // ("foo — bar") that we DO NOT want to collapse to "foobar".
    {
      let i = endIdx;
      if (i < blockText.length && isDash(blockText[i])) {
        let j = i + 1;
        while (j < blockText.length && /\s/.test(blockText[j])) j++;
        const ws = j;
        while (j < blockText.length && WORD_RE.test(blockText[j])) j++;
        if (j > ws) return base + blockText.substring(ws, j);
      }
    }
    // Case C: walking back across whitespace before our word, the previous
    // char is a dash. Symmetric mirror of Case B from the continuation
    // half's point of view: pattern "first- <whitespace> us".
    {
      let k = idx;
      while (k > 0 && /\s/.test(blockText[k - 1])) k--;
      if (k > 0 && isDash(blockText[k - 1])) {
        let endPrev = k - 1;
        let startPrev = endPrev;
        while (startPrev > 0 && WORD_RE.test(blockText[startPrev - 1])) startPrev--;
        if (endPrev > startPrev) {
          return blockText.substring(startPrev, endPrev) + base;
        }
      }
    }
    return base;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else {
    main();
  }
})();
