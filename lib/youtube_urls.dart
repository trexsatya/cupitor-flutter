/// Recognising a YouTube video link, including one already rewritten to an
/// alternative front-end.
///
/// Links clicked inside the app are rewritten to the user's Invidious/Piped
/// instance before any dialog sees them, so a check against youtube.com alone
/// misses exactly the URLs the app itself produced. Kept free of Flutter so
/// the host rules can be tested directly.
library;

/// True when [url] plays a video — on YouTube, or on [frontend] if one is
/// configured.
///
/// Deliberately looser than extracting a video id: this only decides whether
/// to offer a replay control, and a link that looks like a watch page but
/// carries an unusual id should still get one.
bool isYouTubeWatchUrl(String url, {String? frontend}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return false;
  final host = uri.host.toLowerCase();

  final onYouTube = host == 'youtu.be' ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com') ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube-nocookie.com');

  final fe = frontend?.trim().toLowerCase();
  final onFrontend = fe != null && fe.isNotEmpty && host == fe;

  if (!onYouTube && !onFrontend) return false;

  // A short link is a video by construction — the path IS the id.
  if (host == 'youtu.be') return uri.pathSegments.isNotEmpty;

  if (uri.queryParameters.containsKey('v')) return true;
  for (final seg in const ['watch', 'shorts', 'embed', 'live', 'v']) {
    if (uri.pathSegments.contains(seg)) return true;
  }
  return false;
}
