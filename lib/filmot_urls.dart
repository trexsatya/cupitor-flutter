bool isFilmotUrl(String? url) {
  final uri = Uri.tryParse(url ?? '');
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      (uri.host == 'filmot.com' || uri.host.endsWith('.filmot.com'));
}

/// Start Filmot's OAuth flow in the browser that will receive its callback.
Uri? filmotBrowserSignInUrl(String initialUrl, String requestedUrl) {
  if (!isFilmotUrl(initialUrl) || !isFilmotUrl(requestedUrl)) return null;
  final request = Uri.parse(requestedUrl);
  if (request.scheme != 'https' || request.userInfo.isNotEmpty) return null;
  final path = request.path.replaceFirst(RegExp(r'/$'), '');
  if (path == '/auth/login') return request;
  if (path == '/auth/patreon/redirect') {
    return Uri(
      scheme: 'https',
      host: request.host,
      port: request.hasPort ? request.port : null,
      path: '/auth/login',
    );
  }
  return null;
}
