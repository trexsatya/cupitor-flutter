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
    // Short-circuit: nothing to wrap in this segment.
    let hasWord = false;
    for (let i = 0; i < words.length; i++) {
      if (words[i].isWord && words[i].text.trim().length > 2) { hasWord = true; break; }
    }
    if (!hasWord) return;
    const frag = document.createDocumentFragment();
    for (const {text: word, isWord} of words) {
      if (!isWord || word.trim().length <= 2) {
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
        if (t) {
          try {
             CaptionHandler.postMessage(t.dataset.word);
          } catch(e) {}
        }
      }, true);
      window.myCustomerListenerAttached = true;
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', main);
  } else {
    main();
  }
})();
