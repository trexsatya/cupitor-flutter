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

  test('Patreon Google popup restarts at Filmot without forwarding state', () {
    const popup =
        'https://accounts.google.com/gsi/select?ux_mode=popup'
        '&origin=https%3A%2F%2Fwww.patreon.com&as=example';
    expect(
      filmotBrowserSignInUrl(results, popup),
      Uri.parse('https://filmot.com/auth/login'),
    );
    expect(
      filmotBrowserSignInUrl('https://beta.filmot.com/search/test/1', popup),
      Uri.parse('https://beta.filmot.com/auth/login'),
    );
    expect(filmotBrowserSignInUrl('https://www.patreon.com', popup), isNull);
    for (final unrelated in [
      popup.replaceFirst('www.patreon.com', 'www.patreon.com.example.org'),
      popup.replaceFirst('ux_mode=popup', 'ux_mode=redirect'),
      popup.replaceFirst(
        'accounts.google.com',
        'accounts.google.com.example.org',
      ),
      popup.replaceFirst('/gsi/select', '/gsi/client'),
    ]) {
      expect(filmotBrowserSignInUrl(results, unrelated), isNull);
    }
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

  test('identifies the video for a Filmot SRT import', () {
    const id = 'NxAaT1Yj9OE';
    for (final link in [
      'https://filmot.com/video/$id/Example',
      'https://beta.filmot.com/sidebyside/$id/auto.sv/sv/Swedish/Swedish',
      'https://filmot.com/search/%22%C3%A5tg%C3%A5ng%22/$id/1?lang=sv',
      'https://youtu.be/$id?t=9',
      'https://www.youtube.com/watch?v=$id',
      id,
    ]) {
      expect(filmotSubtitleVideoId(' $link '), id, reason: link);
    }
  });

  test('an SRT cannot be assigned to a Filmot search without a video', () {
    for (final link in [
      'https://filmot.com/search/NxAaT1Yj9OE/1?lang=sv',
      'https://filmot.com/search/sondera/1?lang=sv',
      'https://filmot.com/video/short',
      'https://filmot.com/auth/login',
      'https://filmot.com.example.com/video/NxAaT1Yj9OE',
      'https://filmot.com@example.com/video/NxAaT1Yj9OE',
    ]) {
      expect(filmotSubtitleVideoId(link), isNull, reason: link);
    }
  });
}
