import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/youtube_urls.dart';

/// Decides whether a dialog gets a replay control, so a false negative costs
/// the user the button on a real video and a false positive puts a dead
/// control on an ordinary page.
void main() {
  group('on youtube itself', () {
    test('watch links, with and without a timestamp', () {
      expect(isYouTubeWatchUrl('https://www.youtube.com/watch?v=abc12345678'), isTrue);
      expect(isYouTubeWatchUrl('https://www.youtube.com/watch?v=abc12345678&t=132'), isTrue);
    });

    test('short, shorts, embed and live forms', () {
      expect(isYouTubeWatchUrl('https://youtu.be/abc12345678?t=90'), isTrue);
      expect(isYouTubeWatchUrl('https://www.youtube.com/shorts/abc12345678'), isTrue);
      expect(isYouTubeWatchUrl('https://www.youtube.com/embed/abc12345678'), isTrue);
      expect(isYouTubeWatchUrl('https://www.youtube.com/live/abc12345678'), isTrue);
    });

    test('m. and nocookie hosts count', () {
      expect(isYouTubeWatchUrl('https://m.youtube.com/watch?v=abc12345678'), isTrue);
      expect(isYouTubeWatchUrl('https://www.youtube-nocookie.com/embed/abc12345678'), isTrue);
    });

    test('a non-video YouTube page gets no replay control', () {
      expect(isYouTubeWatchUrl('https://www.youtube.com/'), isFalse);
      expect(isYouTubeWatchUrl('https://www.youtube.com/feed/subscriptions'), isFalse);
      expect(isYouTubeWatchUrl('https://www.youtube.com/@somechannel'), isFalse);
    });

    test('a bare youtu.be with no path is not a video', () {
      expect(isYouTubeWatchUrl('https://youtu.be/'), isFalse);
    });
  });

  group('on a configured front-end', () {
    // This is the case a youtube.com-only check misses: the app rewrites
    // links to the chosen instance before a dialog ever sees them.
    test('a rewritten watch link is recognised', () {
      expect(
        isYouTubeWatchUrl('https://yewtu.be/watch?v=abc12345678&t=132',
            frontend: 'yewtu.be'),
        isTrue,
      );
    });

    test('the same link is NOT recognised when no front-end is configured', () {
      expect(isYouTubeWatchUrl('https://yewtu.be/watch?v=abc12345678'), isFalse);
      expect(
        isYouTubeWatchUrl('https://yewtu.be/watch?v=abc12345678', frontend: ''),
        isFalse,
      );
    });

    test('a different front-end host does not match', () {
      expect(
        isYouTubeWatchUrl('https://yewtu.be/watch?v=abc12345678',
            frontend: 'piped.video'),
        isFalse,
      );
    });

    test('the front-end home page is not a video', () {
      expect(isYouTubeWatchUrl('https://yewtu.be/', frontend: 'yewtu.be'), isFalse);
    });

    test('front-end matching ignores case and stray whitespace', () {
      expect(
        isYouTubeWatchUrl('https://yewtu.be/watch?v=abc12345678',
            frontend: '  YewTu.Be '),
        isTrue,
      );
    });
  });

  group('everything else', () {
    test('an unrelated site is never a video', () {
      expect(isYouTubeWatchUrl('https://filmot.com/search'), isFalse);
      expect(isYouTubeWatchUrl('https://example.com/watch?v=abc12345678'), isFalse);
    });

    // A look-alike host is the one that would actually be exploited by a page
    // linking somewhere unexpected.
    test('a look-alike host does not pass', () {
      expect(isYouTubeWatchUrl('https://notyoutube.com/watch?v=abc'), isFalse);
      expect(isYouTubeWatchUrl('https://youtube.com.evil.test/watch?v=abc'), isFalse);
    });

    test('junk input is handled rather than thrown', () {
      expect(isYouTubeWatchUrl(''), isFalse);
      expect(isYouTubeWatchUrl('not a url'), isFalse);
      expect(isYouTubeWatchUrl('watch?v=abc12345678'), isFalse); // no authority
    });
  });
}
