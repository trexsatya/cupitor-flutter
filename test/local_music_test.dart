import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/local_music.dart';

void main() {
  group('musicSafeFileName', () {
    test('keeps an ordinary name, extension included', () {
      expect(musicSafeFileName('Kalinka.mp3'), 'Kalinka.mp3');
      expect(musicSafeFileName('My Song (live).m4a'), 'My Song (live).m4a');
    });

    test('keeps letters in any script', () {
      expect(musicSafeFileName('Калинка.mp3'), 'Калинка.mp3');
      expect(musicSafeFileName('春よ、来い.flac'), '春よ、来い.flac');
    });

    test('takes the basename of a path', () {
      expect(musicSafeFileName('/sdcard/Music/a.mp3'), 'a.mp3');
      expect(musicSafeFileName(r'C:\Music\a.mp3'), 'a.mp3');
    });

    test('replaces characters a filesystem or url path would choke on', () {
      expect(musicSafeFileName('a:b*c?d"e<f>g|h%i#j.mp3'), 'a_b_c_d_e_f_g_h_i_j.mp3');
      expect(musicSafeFileName('a\u0000b.mp3'), 'a_b.mp3');
    });

    test('never returns something that hides or escapes', () {
      expect(musicSafeFileName(''), 'track');
      expect(musicSafeFileName('.'), 'track');
      expect(musicSafeFileName('..'), 'track');
      expect(musicSafeFileName('.hidden.mp3'), 'hidden.mp3');
      expect(musicSafeFileName('   '), 'track');
    });
  });

  group('musicDisplayName', () {
    test('drops the extension and any directory', () {
      expect(musicDisplayName('Kalinka.mp3'), 'Kalinka');
      expect(musicDisplayName('/a/b/Kalinka (2).mp3'), 'Kalinka (2)');
      expect(musicDisplayName('noext'), 'noext');
      expect(musicDisplayName('.mp3'), '.mp3');
    });
  });

  group('musicSplitExt', () {
    test('splits stem and extension', () {
      expect(musicSplitExt('Song.mp3'), ('Song', '.mp3'));
      expect(musicSplitExt('Song.v2.mp3'), ('Song.v2', '.mp3'));
      expect(musicSplitExt('Song'), ('Song', ''));
      expect(musicSplitExt('.mp3'), ('.mp3', ''));
    });
  });

  group('filePathInsideDir', () {
    const dir = '/data/user/0/org.satya.cupitor/app_flutter/music';

    test('accepts a file directly inside the directory', () {
      expect(filePathInsideDir('file://$dir/Kalinka.mp3', dir), '$dir/Kalinka.mp3');
      expect(filePathInsideDir('file://$dir/Kalinka.mp3', '$dir/'), '$dir/Kalinka.mp3');
    });

    test('refuses an escape that only appears after collapsing dots', () {
      // This is the case a bare prefix check waves through.
      expect(filePathInsideDir('file://$dir/../manual_audio/rec.ogg', dir), isNull);
      expect(filePathInsideDir('file://$dir/./../music2/x.mp3', dir), isNull);
    });

    test('refuses anything that is not a bare file in the directory', () {
      expect(filePathInsideDir('file://$dir', dir), isNull);
      expect(filePathInsideDir('file://$dir/', dir), isNull);
      expect(filePathInsideDir('file://$dir/sub/x.mp3', dir), isNull);
      expect(filePathInsideDir('file:///etc/passwd', dir), isNull);
      expect(filePathInsideDir('file://${dir}2/x.mp3', dir), isNull);
    });

    test('refuses non-file urls', () {
      expect(filePathInsideDir('https://example.com/x.mp3', dir), isNull);
      expect(filePathInsideDir('', dir), isNull);
      expect(filePathInsideDir('file://', dir), isNull);
    });
  });
}
