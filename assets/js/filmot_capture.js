(function(){
  if (location.protocol !== 'https:' && location.protocol !== 'http:') return null;
  if (location.hostname !== 'filmot.com' && !location.hostname.endsWith('.filmot.com')) return null;
  var query = '';
  try {
    // Filmot search URL: /search/%22word%22/N → first segment after
    // /search/ is the (URI-encoded) quoted query.
    var m = location.pathname.match(/\/search\/([^/]+)/);
    if (m) {
      var raw = decodeURIComponent(m[1]);
      // decodeURIComponent already converts %22 → ", so this strips
      // the literal surrounding quotes left from the filmot syntax.
      raw = raw.replace(/^["']+|["']+$/g, '');
      query = raw;
    }
  } catch(e){}
  // Identify the currently-playing video. iframe.src is the most
  // reliable signal because filmot's Next/Prev swaps the src in place.
  function ytId(href) {
    if (!href) return null;
    var pats = [
      /youtube\.com\/embed\/([A-Za-z0-9_-]{6,})/,
      /youtube\.com\/watch\?v=([A-Za-z0-9_-]{6,})/,
      /youtu\.be\/([A-Za-z0-9_-]{6,})/,
      /[?&]v=([A-Za-z0-9_-]{6,})/,
      /\/sidebyside\/([A-Za-z0-9_-]{6,})/
    ];
    for (var p = 0; p < pats.length; p++) { var mmId = href.match(pats[p]); if (mmId) return mmId[1]; }
    return null;
  }
  var videoId = null;
  var ifr = document.getElementById('player');
  if (ifr && ifr.src) videoId = ytId(ifr.src);
  if (!videoId) {
    var ax = document.querySelector('#divVideoDetails a[href*="watch?v="], #linktoyoutube a[href*="watch?v="]');
    if (ax) videoId = ytId(ax.href || ax.getAttribute('href') || '');
  }
  if (!videoId) {
    var pmSb = location.pathname.match(/\/sidebyside\/([A-Za-z0-9_-]{6,})/);
    if (pmSb) videoId = pmSb[1];
  }
  var videoTitle = '';
  var titleEl = document.querySelector('#divVideoDetails .col-6');
  if (titleEl) videoTitle = (titleEl.textContent || '').trim().split(/\s*[\r\n]+/)[0].slice(0, 200);
  if (!videoTitle) videoTitle = (document.title || '').trim();
  // Filmot links the uploader as /channel/<id>, next to the title.
  var chEl = document.querySelector('#divVideoDetails a[href*="/channel/"]');
  var videoChannel = chEl ? (chEl.textContent || '').trim().slice(0, 100) : '';
  var divs = document.querySelectorAll('#subtitlesIn > div[id^="s"]');
  var lines = [];
  for (var i = 0; i < divs.length; i++) {
    var div = divs[i];
    var a = div.querySelector('a[href*="jtt("]');
    var ts = 0;
    if (a) {
      var mm = a.getAttribute('href').match(/jtt\((\d+),([\d.]+)\)/);
      if (mm) ts = parseFloat(mm[2]);
    }
    var clone = div.cloneNode(true);
    var anc = clone.querySelector('a');
    if (anc) anc.parentNode.removeChild(anc);
    var text = (clone.textContent || '').replace(/ /g, ' ').replace(/\s+/g, ' ').trim();
    var idM = div.id.match(/^s(\d+)/);
    lines.push({ i: idM ? parseInt(idM[1], 10) : i, ts: ts, t: text });
  }
  // --- Robust match resolution ---
  // Filmot does fuzzy/stemmed search across word forms (esp. in highly
  // inflected languages like Swedish), so an exact substring lookup on
  // the query word often misses. Try a cascade of strategies and remember
  // which one fired so the UI can flag fallbacks.
  function stripDiacritics(s) {
    try { return s.normalize('NFD').replace(/[̀-ͯ]/g, ''); }
    catch(e) { return s; }
  }
  function findMatch(lines, query) {
    if (!query) return { idx: -1, reason: 'no-query' };
    var q = query.toLowerCase();
    // 1) Exact substring.
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].t.toLowerCase().indexOf(q) !== -1) return { idx: i, reason: 'exact' };
    }
    // 2) Diacritic-insensitive substring (e.g. "atgang" matches "åtgång").
    var qs = stripDiacritics(q);
    if (qs !== q) {
      for (var i2 = 0; i2 < lines.length; i2++) {
        if (stripDiacritics(lines[i2].t.toLowerCase()).indexOf(qs) !== -1) return { idx: i2, reason: 'normalized' };
      }
    }
    // 3) Stemmed prefix — drop trailing chars to catch inflections
    // ("vakna" should match "vaknade", "vaknar", "vaknat", "vakn-up", ...).
    for (var trim = 1; trim <= 4 && q.length - trim >= 3; trim++) {
      var qt = stripDiacritics(q.substring(0, q.length - trim));
      for (var i3 = 0; i3 < lines.length; i3++) {
        if (stripDiacritics(lines[i3].t.toLowerCase()).indexOf(qt) !== -1) return { idx: i3, reason: 'stem(-' + trim + ')' };
      }
    }
    // 4) Word-overlap — for multi-word queries, find the line containing
    // the largest number of query tokens.
    var tokens = q.split(/\s+/).filter(function(w){ return w.length > 1; });
    if (tokens.length > 1) {
      var best = -1, bestN = 0;
      for (var i4 = 0; i4 < lines.length; i4++) {
        var lt = stripDiacritics(lines[i4].t.toLowerCase());
        var n = 0;
        for (var t = 0; t < tokens.length; t++) {
          if (lt.indexOf(stripDiacritics(tokens[t])) !== -1) n++;
        }
        if (n > bestN) { bestN = n; best = i4; }
      }
      if (best >= 0 && bestN >= Math.max(1, Math.ceil(tokens.length / 2))) {
        return { idx: best, reason: 'tokens(' + bestN + '/' + tokens.length + ')' };
      }
    }
    return { idx: -1, reason: 'no-match' };
  }
  var resolved = findMatch(lines, query);
  var matchIdx = resolved.idx;
  var matchReason = resolved.reason;
  // 5) Time-based fallback — anchor at whatever subtitle is playing right now.
  if (matchIdx < 0 && lines.length) {
    try {
      var ct = null;
      if (window.player && typeof window.player.getCurrentTime === 'function') {
        ct = window.player.getCurrentTime();
      }
      if (typeof ct === 'number' && ct >= 0) {
        for (var ti = 0; ti < lines.length; ti++) {
          var nxt = (ti + 1 < lines.length) ? lines[ti + 1].ts : (lines[ti].ts + 3);
          if (ct >= lines[ti].ts && ct < nxt) { matchIdx = ti; matchReason = 'currentTime'; break; }
        }
        if (matchIdx < 0) { matchIdx = lines.length - 1; matchReason = 'currentTime'; }
      }
    } catch(e) {}
  }
  // 6) Last resort: first non-empty line.
  if (matchIdx < 0) {
    for (var fi = 0; fi < lines.length; fi++) {
      if ((lines[fi].t || '').trim().length) { matchIdx = fi; matchReason = 'firstNonEmpty'; break; }
    }
  }
  return JSON.stringify({
    query: query,
    lines: lines,
    matchIdx: matchIdx,
    matchReason: matchReason,
    videoId: videoId || '',
    videoUrl: videoId ? ('https://www.youtube.com/watch?v=' + videoId) : '',
    videoTitle: videoTitle,
    videoChannel: videoChannel
  });
})();
