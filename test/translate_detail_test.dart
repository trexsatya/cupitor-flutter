import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cupitor/translate_detail.dart';

/// The input is Google's undocumented `translate_a/single` array. It can change
/// shape without notice, so the parser's job is to salvage the primary
/// translation whatever else happens and never throw back at the caller.
void main() {
  TranslateDetail parse(String json) =>
      parseTranslateResponse(jsonDecode(json) as Object?);

  group('primary translation', () {
    test('joins every segment', () {
      final d = parse('[[["I went home.","Jag gick hem.",null,null,10],'
          '[" It was late.","Det var sent.",null,null,10]],null,"sv"]');
      expect(d.primary, 'I went home. It was late.');
    });

    test('survives a response with nothing but segments', () {
      expect(parse('[[["lake","sjö",null,null,10]]]').primary, 'lake');
    });

    test('skips null segment texts rather than writing "null"', () {
      final d = parse('[[["lake","sjö",null,null,10],[null,null,null,null,3]]]');
      expect(d.primary, 'lake');
    });
  });

  // Captured verbatim from translate.googleapis.com on 2026-09-12 (sv→en,
  // dt=t&dt=bd&dt=at). Fixtures invented from the documented shape got the
  // score position wrong — it sits at index 3 with index 2 null, and most
  // terms have no score at all — so these stay byte-for-byte as returned.
  group('senses, against real responses', () {
    const ta = '[[["take","ta",null,null,2]],[["verb",["take","carry","embrace",'
        '"treat","score","wreak","shoot"],[["take",["ta","vidta","fatta","taga",'
        '"gripa","antaga"],null,0.28206295],["carry",["bära","föra","transportera",'
        '"ha","bära på","ta"]],["embrace",["omfamna","omfatta","famna","krama",'
        '"anta","ta"]],["treat",["behandla","bemöta","undfägna","betrakta",'
        '"bearbeta","ta"]],["score",["göra","göra mål","göra skåror i",'
        '"göra repor på","göra streck på","ta"]],["wreak",["utlösa","utkräva",'
        '"förorsaka","ta","utgjuta"]],["shoot",["skjuta","fotografera","spela",'
        '"filma","fyra av","ta"]]],"ta",2]],"sv",null,null,[["ta",null,'
        '[["take",null,true,false,[2]],["to take",null,true,false,[8]]],'
        '[[0,2]],"ta",0,0]],null,[]]';

    const sjo = '[[["lake","sjö",null,null,2]],[["noun",["lake","sea","wave",'
        '"mere","lough","loch"],[["lake",["sjö","insjö","rödaktigt färgämne"],'
        'null,0.47980523],["sea",["hav","sjö","farvatten","ström","sjögång",'
        '"våg"],null,0.031646587],["wave",["våg","sjö","ondulering","permanent",'
        '"vågformighet","vink"]],["mere",["sjö","göl"]],["lough",["sjö",'
        '"havsvik"]],["loch",["sjö","havsvik"]]],"sjö",1]],"sv",null,null,'
        '[["sjö",null,[["lake",null,true,false,[2]],["sea",null,true,false,[8]]],'
        '[[0,3]],"sjö",0,0]],null,[]]';

    // The whole point of the feature: "ta" is seven different English verbs,
    // and the bare translation silently picks one.
    test('a word with many senses yields all of them, in response order', () {
      final d = parse(ta);
      expect(d.primary, 'take');
      expect(d.senses.single.pos, 'verb');
      expect(d.senses.single.terms.map((t) => t.term).toList(),
          ['take', 'carry', 'embrace', 'treat', 'score', 'wreak', 'shoot']);
    });

    test('reads the score from index 3, where the response actually puts it', () {
      final terms = parse(sjo).senses.single.terms;
      expect(terms[0].term, 'lake');
      expect(terms[0].score, closeTo(0.47980523, 1e-9));
      expect(terms[1].term, 'sea');
      expect(terms[1].score, closeTo(0.031646587, 1e-9));
    });

    // Only the leading senses carry a score, so anything ordering these has to
    // fall back to response order rather than assume a sortable number.
    test('a term row with no score at all yields null, not zero', () {
      final terms = parse(sjo).senses.single.terms;
      expect(terms[2].term, 'wave');
      expect(terms[2].score, isNull);
    });

    test('carries reverse translations', () {
      expect(parse(sjo).senses.single.terms.first.reverse,
          ['sjö', 'insjö', 'rödaktigt färgämne']);
      expect(parse(ta).senses.single.terms.first.reverse,
          ['ta', 'vidta', 'fatta', 'taga', 'gripa', 'antaga']);
    });

    test('reads alternates out of the real block', () {
      expect(parse(ta).alternates, ['take', 'to take']);
      expect(parse(sjo).alternates, ['lake', 'sea']);
    });

    // The assumption the whole design rests on: Google itself distinguishes a
    // word from a sentence, so there is no length heuristic to tune.
    test('a real sentence returns a null dictionary block, so no senses', () {
      final d = parse('[[["I went to the store to buy milk",'
          '"Jag gick till affären för att köpa mjölk",null,null,3,null,null,'
          '[[]],[[["1eb561d2d816b8957a38cd5018eb164c","tea_AllEn_2022q2.md"]]]]],'
          'null,"sv",null,null,[["Jag gick till affären för att köpa mjölk",null,'
          '[["I went to the store to buy milk",null,true,false,[3],null,[[3]]],'
          '["I went to the shop to buy some milk",null,true,false,[8]]],'
          '[[0,40]],"Jag gick till affären för att köpa mjölk",0,0]],null,[]]');
      expect(d.primary, 'I went to the store to buy milk');
      expect(d.senses, isEmpty);
      // Alternates DO come back for a sentence, so they are not a signal for
      // "this was a word" — only `senses` is.
      expect(d.alternates,
          ['I went to the store to buy milk', 'I went to the shop to buy some milk']);
    });

    test('still reads a score at index 2, should the shape ever move back', () {
      final d = parse('[[["lake","sjö",null,null,10]],'
          '[["noun",["lake"],[["lake",["sjö"],0.62,true]],"sjö",1]],"sv"]');
      expect(d.senses.single.terms.single.score, closeTo(0.62, 1e-9));
    });

    test('groups terms under their part of speech, in order', () {
      final d = parse('[[["take","ta",null,null,10]],'
          '[["verb",["take"],[["take",["ta"],null,0.6]],"ta",1],'
          '["noun",["taking"],[["taking",["tagande"],null,0.01]],"ta",2]],"sv"]');
      expect(d.senses.map((s) => s.pos).toList(), ['verb', 'noun']);
      expect(d.senses.last.terms.single.term, 'taking');
    });

    test('a term with no reverse list still yields a sense', () {
      final d = parse('[[["lake","sjö",null,null,10]],'
          '[["noun",["lake"],[["lake",null,0.9,true]],"sjö",1]],"sv"]');
      expect(d.senses.single.terms.single.reverse, isEmpty);
      expect(d.senses.single.terms.single.term, 'lake');
    });

    test('drops entries with an empty term instead of emitting blanks', () {
      final d = parse('[[["lake","sjö",null,null,10]],'
          '[["noun",["lake"],[["",["sjö"],0.9,true],["sea",["hav"],0.1,true]],"sjö",1]],'
          '"sv"]');
      expect(d.senses.single.terms.map((t) => t.term).toList(), ['sea']);
    });

    test('drops a part-of-speech group once all its terms are unusable', () {
      final d = parse('[[["lake","sjö",null,null,10]],'
          '[["noun",["lake"],[["",null,0.9,true]],"sjö",1]],"sv"]');
      expect(d.senses, isEmpty);
    });
  });

  group('alternates', () {
    test('reads the alternate-translation block when present', () {
      final d = parse('[[["lake","sjö",null,null,10]],null,"sv",null,null,'
          '[["sjö",null,[["lake",0,true,false],["sea",0,true,false]],'
          '[[0,3]],"sjö",0,0]]]');
      expect(d.alternates, ['lake', 'sea']);
    });

    test('is empty when the block is absent', () {
      expect(parse('[[["lake","sjö",null,null,10]],null,"sv"]').alternates,
          isEmpty);
    });
  });

  group('malformed input never throws', () {
    // Each of these is a shape Google could start returning tomorrow. The
    // contract is: salvage what you can, lose the rest, stay quiet.
    test('empty array', () {
      final d = parse('[]');
      expect(d.primary, '');
      expect(d.senses, isEmpty);
    });

    test('null', () {
      final d = parseTranslateResponse(null);
      expect(d.primary, '');
      expect(d.senses, isEmpty);
    });

    test('not a list at all', () {
      final d = parseTranslateResponse(<String, Object?>{'oops': true});
      expect(d.primary, '');
    });

    test('segments block is the wrong type', () {
      expect(parse('["not-a-list",null,"sv"]').primary, '');
    });

    test('dictionary block is the wrong type, primary still survives', () {
      final d = parse('[[["lake","sjö",null,null,10]],"nonsense","sv"]');
      expect(d.primary, 'lake');
      expect(d.senses, isEmpty);
    });

    test('dictionary entry is a bare string', () {
      final d = parse('[[["lake","sjö",null,null,10]],["noun"],"sv"]');
      expect(d.primary, 'lake');
      expect(d.senses, isEmpty);
    });

    test('score is a string rather than a number', () {
      final d = parse('[[["lake","sjö",null,null,10]],'
          '[["noun",["lake"],[["lake",["sjö"],"high",true]],"sjö",1]],"sv"]');
      expect(d.senses.single.terms.single.score, isNull);
      expect(d.senses.single.terms.single.term, 'lake');
    });
  });

  group('toJson', () {
    // The keys are always present — the page can iterate without guarding.
    // A sentence yields them empty rather than absent.
    test('keeps senses and alternates as empty lists for a sentence', () {
      final j = parse('[[["I went home.","Jag gick hem.",null,null,10]],null,"sv"]')
          .toJson(provider: 'google');
      expect(j.containsKey('senses'), isTrue);
      expect(j.containsKey('alternates'), isTrue);
      expect(j['provider'], 'google');
      expect(j['senses'], isEmpty);
      expect(j['alternates'], isEmpty);
    });

    // score IS conditional, unlike senses/alternates: an absent key means
    // "unknown", which is not the same claim as a score of zero.
    test('omits a term score entirely when the response had no number', () {
      final j = parse('[[["lake","sjö",null,null,10]],'
              '[["noun",["lake"],[["lake",["sjö"],"high",true]],"sjö",1]],"sv"]')
          .toJson(provider: 'google');
      final term = (((j['senses'] as List).single
          as Map<String, dynamic>)['terms'] as List).single as Map<String, dynamic>;
      expect(term.containsKey('score'), isFalse);
      expect(term['term'], 'lake');
    });

    test('includes a term score when the response had one', () {
      final j = parse('[[["lake","sjö",null,null,10]],'
              '[["noun",["lake"],[["lake",["sjö"],0.9,true]],"sjö",1]],"sv"]')
          .toJson(provider: 'google');
      final term = (((j['senses'] as List).single
          as Map<String, dynamic>)['terms'] as List).single as Map<String, dynamic>;
      expect(term['score'], closeTo(0.9, 1e-9));
    });

    test('an offline answer is labelled so empty senses are not read as one sense', () {
      final j = const TranslateDetail.empty().toJson(provider: 'mlkit');
      expect(j['provider'], 'mlkit');
      expect(j['senses'], isEmpty);
    });

    test('round-trips through jsonEncode for the bridge', () {
      final j = parse('[[["take","ta",null,null,10]],'
              '[["verb",["take"],[["take",["ta"],0.6,true]],"ta",1]],"sv"]')
          .toJson(provider: 'google');
      final back = jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
      final sense = (back['senses'] as List).single as Map<String, dynamic>;
      expect(sense['pos'], 'verb');
      final term = (sense['terms'] as List).single as Map<String, dynamic>;
      expect(term['term'], 'take');
      expect(term['reverse'], ['ta']);
      expect(term['score'], closeTo(0.6, 1e-9));
    });
  });
}
