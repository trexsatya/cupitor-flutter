(function(capture) {
  // The embedded lookup uses the same bridge as the other Filmot actions.
  // Native browser windows still receive the result from evaluateJavaScript.
  if (typeof cupitorFilmotCaptureRequestId !== 'number') {
    var result = capture();
    return result === null ? null : JSON.stringify(result);
  }

  var requestId = cupitorFilmotCaptureRequestId;
  function read(attempt) {
    var result;
    try {
      result = capture();
    } catch (error) {
      FilmotBridge.postMessage(JSON.stringify({
        action: 'subtitleCapture', requestId: requestId, error: String(error)
      }));
      return;
    }

    // Filmot can populate captions after switching to a different result.
    if ((!result || !result.lines.length) && attempt < 3) {
      setTimeout(function() { read(attempt + 1); }, 500);
      return;
    }
    FilmotBridge.postMessage(JSON.stringify({
      action: 'subtitleCapture', requestId: requestId, capture: result
    }));
  }
  read(0);
})(function(){
  function isFilmotDocument(doc) {
    var loc = doc && doc.location;
    return !!loc && (loc.protocol === 'https:' || loc.protocol === 'http:') &&
      (loc.hostname === 'filmot.com' || loc.hostname.endsWith('.filmot.com'));
  }
  if (!isFilmotDocument(document)) return null;

  var jumpSelector = 'a[href*="jtt"], [onclick*="jtt"]';
  function captionText(node) {
    return (node.textContent || '').replace(/^\s*[▶►▸]+\s*/, '').replace(/\s+/g, ' ').trim();
  }

  function readLines(root) {
    var lines = [];
    var seen = new Set();
    var links = root.querySelectorAll(jumpSelector);
    for (var i = 0; i < links.length; i++) {
      var link = links[i];
      var call = (link.getAttribute('href') || '') + ' ' + (link.getAttribute('onclick') || '');
      var timing = call.match(/jtt\s*\(\s*['"]?\d+['"]?\s*,\s*['"]?(\d+(?:\.\d+)?)/);
      if (!timing) continue;
      var row = link;
      while (row !== root && !/^s\d+/.test(row.id)) {
        row = row.parentElement;
      }
      if (row === root) row = link.parentElement.closest('div, li, p, tr');
      if (!row || row === root || !root.contains(row)) row = link;
      if (seen.has(row)) continue;
      var clone = row.cloneNode(true);
      var control = clone.querySelector(jumpSelector);
      if (control) control.remove();
      // On some layouts the clickable row wraps the caption itself.
      var text = captionText(clone) || captionText(row);
      if (!text) continue;
      seen.add(row);
      var id = row.id.match(/^s(\d+)/);
      lines.push({i: id ? parseInt(id[1], 10) : lines.length, ts: Number(timing[1]), t: text});
    }
    return lines;
  }

  // Search and detail views can put the transcript inside a same-origin
  // frame. Never read a YouTube embed or a different site's document.
  var docs = [document];
  var page = document;
  var lines = [];
  for (var d = 0; d < docs.length; d++) {
    var doc = docs[d];
    var root = doc.getElementById('subtitlesIn');
    if (root) lines = readLines(root);
    if (!lines.length) {
      var panels = doc.querySelectorAll('.scroll-subtitles:not(#subtitlesIn)');
      for (var r = 0; r < panels.length && !lines.length; r++) {
        lines = readLines(panels[r]);
      }
    }
    if (lines.length) { page = doc; break; }
    var frames = doc.querySelectorAll('iframe, frame');
    for (var f = 0; f < frames.length; f++) {
      var child = frames[f].contentDocument;
      if (isFilmotDocument(child)) docs.push(child);
    }
  }

  function searchQuery(doc) {
    try {
      var match = doc.location.pathname.match(/\/search\/([^/]+)/);
      return match ? decodeURIComponent(match[1]).replace(/^["']+|["']+$/g, '') : '';
    } catch (_) { return ''; }
  }
  var query = searchQuery(page) || searchQuery(document);
  function metadata(selector) {
    return page.querySelector(selector) || document.querySelector(selector);
  }
  // Identify the currently-playing video. iframe.src is the most
  // reliable signal because filmot's Next/Prev swaps the src in place.
  function ytId(href) {
    if (typeof href !== 'string' || !href) return null;
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
  var ifr = metadata('#player');
  if (ifr && ifr.src) videoId = ytId(ifr.src);
  if (!videoId) {
    var ax = metadata('#divVideoDetails a[href*="watch?v="], #linktoyoutube a[href*="watch?v="]');
    if (ax) videoId = ytId(ax.href || ax.getAttribute('href') || '');
  }
  function videoIdFromPath(doc) {
    var path = doc.location.pathname;
    var match = path.match(/^\/sidebyside\/([A-Za-z0-9_-]{6,})/) ||
      path.match(/^\/search\/[^/]+\/([A-Za-z0-9_-]{11})\/[0-9]+(?:\/|$)/);
    return match ? match[1] : null;
  }
  if (!videoId) videoId = videoIdFromPath(page) || videoIdFromPath(document);
  var videoTitle = '';
  var titleEl = metadata('#divVideoDetails .col-6');
  if (titleEl) videoTitle = (titleEl.textContent || '').trim().split(/\s*[\r\n]+/)[0].slice(0, 200);
  if (!videoTitle) videoTitle = (page.title || document.title || '').trim();
  // Filmot links the uploader as /channel/<id>, next to the title.
  var chEl = metadata('#divVideoDetails a[href*="/channel/"]');
  var videoChannel = chEl ? (chEl.textContent || '').trim().slice(0, 100) : '';
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
      var player = page.defaultView && page.defaultView.player;
      if (player && typeof player.getCurrentTime === 'function') {
        ct = player.getCurrentTime();
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
  return {
    query: query,
    lines: lines,
    matchIdx: matchIdx,
    matchReason: matchReason,
    videoId: videoId || '',
    videoUrl: videoId ? ('https://www.youtube.com/watch?v=' + videoId) : '',
    videoTitle: videoTitle,
    videoChannel: videoChannel
  };
});
