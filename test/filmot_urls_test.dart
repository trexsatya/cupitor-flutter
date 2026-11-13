import 'package:cupitor/filmot_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const results = 'https://filmot.com/search/sondera/1?lang=sv';

  test('Filmot login hands off to the browser and preserves the URL', () {
    const login = 'https://filmot.com/auth/login?next=%2Fsettings';
    expect(filmotBrowserSignInUrl(results, login), Uri.parse(login));
  });

  test('a Patreon shortcut restarts at Filmot login in the browser', () {
    expect(
      filmotBrowserSignInUrl(
        results,
        'https://beta.filmot.com/auth/patreon/redirect?state=old#start',
      ),
      Uri.parse('https://beta.filmot.com/auth/login'),
    );
  });

  test('search, settings, callbacks, and unrelated sites stay in Cupitor', () {
    for (final url in [
      results,
      'https://filmot.com/settings',
      'https://filmot.com/auth/patreon/callback',
      'https://notfilmot.com/auth/login',
      'https://filmot.com.example.org/auth/login',
      'https://filmot.com@example.com/auth/login',
      'https://someone@filmot.com/auth/login',
      'http://filmot.com/auth/login',
    ]) {
      expect(filmotBrowserSignInUrl(results, url), isNull, reason: url);
    }
    expect(
      filmotBrowserSignInUrl(
        'https://example.org',
        'https://filmot.com/auth/login',
      ),
      isNull,
    );
  });
}
