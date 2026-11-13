import 'youtube_sidebar_subtitles.dart';

bool isFilmotUrl(String? url) {
  final uri = Uri.tryParse(url ?? '');
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      (uri.host == 'filmot.com' || uri.host.endsWith('.filmot.com'));
}

/// Resolves the video whose subtitles were exported from Filmot. Search
/// lists without a selected video have no video ID in their URL.
String? filmotSubtitleVideoId(String input) {
  final value = input.trim();
  if (!isFilmotUrl(value)) return youtubeSubtitleVideoId(value);

  final uri = Uri.parse(value);
  if (uri.userInfo.isNotEmpty) return null;
  final segments = uri.pathSegments;
  if (segments.length < 2) return null;
  final id = switch (segments.first) {
    'video' || 'sidebyside' => segments[1],
    'search' when segments.length >= 4 => segments[2],
    _ => '',
  };
  return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id) ? id : null;
}

/// Start Filmot's OAuth flow in the browser that will receive its callback.
Uri? filmotBrowserSignInUrl(String initialUrl, String requestedUrl) {
  if (!isFilmotUrl(initialUrl)) return null;
  final request = Uri.tryParse(requestedUrl);
  if (request == null ||
      request.scheme != 'https' ||
      request.userInfo.isNotEmpty) {
    return null;
  }
  final path = request.path.replaceFirst(RegExp(r'/$'), '');
  final filmotRequest = isFilmotUrl(requestedUrl);
  if (filmotRequest && path == '/auth/login') return request;

  // If Patreon has already opened Google's account picker inside the WebView,
  // restart with Filmot. The picker URL belongs to the embedded popup session.
  final patreonGooglePopup =
      request.host == 'accounts.google.com' &&
      path == '/gsi/select' &&
      request.queryParameters['ux_mode'] == 'popup' &&
      const {
        'https://www.patreon.com',
        'https://patreon.com',
      }.contains(request.queryParameters['origin']);
  if (patreonGooglePopup ||
      (filmotRequest && path == '/auth/patreon/redirect')) {
    final filmot = filmotRequest ? request : Uri.parse(initialUrl);
    return Uri(
      scheme: 'https',
      host: filmot.host,
      port: filmot.hasPort ? filmot.port : null,
      path: '/auth/login',
    );
  }
  return null;
}
