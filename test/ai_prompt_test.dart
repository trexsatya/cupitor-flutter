import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/ai_prompt.dart';

/// The template is user-editable, so the substitution has to cope with
/// whatever someone types into the box — including nothing.
void main() {
  String render(String template) => renderAiPrompt(
        template,
        word: 'sjö',
        source: 'Swedish',
        target: 'English',
      );

  group('substitution', () {
    test('fills every placeholder', () {
      expect(
        render('Translate {word} from {source} to {target}.'),
        'Translate sjö from Swedish to English.',
      );
    });

    test('fills a placeholder used more than once', () {
      expect(
        render('{word}, and again {word}.'),
        'sjö, and again sjö.',
      );
    });

    test('leaves a template that uses no placeholders untouched', () {
      expect(render('List ten Swedish idioms.'), 'List ten Swedish idioms.');
    });

    test('leaves an unknown placeholder alone rather than blanking it', () {
      expect(render('{word} — {pos}'), 'sjö — {pos}');
    });

    test('does not mangle braces that are not placeholders', () {
      expect(render('JSON like {"a": 1} for {word}'), 'JSON like {"a": 1} for sjö');
    });

    test('substitutes the values verbatim, including regex-special ones', () {
      // replaceAll on a String pattern is literal, so a word like "c++" or
      // one containing $ must survive untouched.
      expect(
        renderAiPrompt('{word}', word: r'a$b.*c++', source: 's', target: 't'),
        r'a$b.*c++',
      );
    });
  });

  group('fallback to the shipped default', () {
    test('an empty template renders the default', () {
      expect(render(''), contains('usage examples/patterns and nuances'));
      expect(render(''), startsWith('Give me translation of "sjö"'));
    });

    test('a whitespace-only template renders the default', () {
      expect(render('   \n  '), startsWith('Give me translation of "sjö"'));
    });

    test('the default itself is fully substituted, leaving no braces behind', () {
      final out = render(kDefaultAiPromptTemplate);
      expect(out, isNot(contains('{')));
      expect(out, contains('sjö'));
      expect(out, contains('Swedish'));
      expect(out, contains('English'));
    });

    // The default is what ships in the Tools editor; if it ever stops
    // mentioning a placeholder, the editor's Reset would quietly produce a
    // prompt that drops the word.
    test('the default mentions each placeholder exactly once', () {
      for (final p in [kAiPromptWord, kAiPromptSource, kAiPromptTarget]) {
        expect(kDefaultAiPromptTemplate.split(p).length - 1, 1, reason: p);
      }
    });
  });
}
