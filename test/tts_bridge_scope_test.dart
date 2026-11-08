import 'package:flutter_test/flutter_test.dart';
import 'package:cupitor/tts_bridge_scope.dart';

void main() {
  test('native TTS polyfill is installed on Cupitor language pages only', () {
    expect(shouldInjectCupitorLanguageTts('https://trexsatya.github.io/language.html?lang=sv'), true);
    expect(shouldInjectCupitorLanguageTts('http://localhost:3000/language.html'), true);
    expect(shouldInjectCupitorLanguageTts('http://127.0.0.1:3000/language.html'), true);
    expect(shouldInjectCupitorLanguageTts('https://example.com/language.html'), false);
    expect(shouldInjectCupitorLanguageTts('https://trexsatya.github.io/reader.html'), false);
    expect(shouldInjectCupitorLanguageTts('garbled url'), false);
  });
}
