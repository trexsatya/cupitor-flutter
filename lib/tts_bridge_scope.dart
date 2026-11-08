/// Limit the native Web Speech polyfill to our own language-learning page.
/// Other sites retain their original WebView speechSynthesis implementation.
bool shouldInjectCupitorLanguageTts(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  if (host != 'trexsatya.github.io' && host != 'localhost' && host != '127.0.0.1') {
    return false;
  }
  return uri.path.endsWith('/language.html');
}
