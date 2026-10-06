import 'package:cupitor/capture_meta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('the Filmot tail after the link icon is dropped', () {
    expect(cleanCapturedTitle('GÅR PÅ CIRKUS MED BARNEN!↗ 359.8K 8.5K 18 Jun 2024'),
        'GÅR PÅ CIRKUS MED BARNEN!');
    expect(cleanCapturedTitle(' Plain title '), 'Plain title');
    expect(cleanCapturedTitle('New Balance Nationals 103.9K 689 11 Mar 2023'), 'New Balance Nationals');
    expect(cleanCapturedTitle('Avsnitt 3 av 12'), 'Avsnitt 3 av 12');
  });

  test('a capture without a channel gets YouTube\'s channel and title', () async {
    final out = await withCaptureMeta(
      {'videoId': 'bpIHLhbiFzQ', 'videoTitle': 'GÅR PÅ CIRKUS!↗ 359.8K'},
      (_) async => (title: 'GÅR PÅ CIRKUS MED BARNEN!', channel: 'Familjen Lundell'),
    );
    expect(out['channel'], 'Familjen Lundell');
    expect(out['videoTitle'], 'GÅR PÅ CIRKUS MED BARNEN!');
  });

  test('a capture that has a channel is not looked up; a failed lookup keeps the cleaned title', () async {
    var asked = 0;
    final kept = await withCaptureMeta({'videoId': 'x', 'videoTitle': 'T', 'channel': 'C'},
        (_) async { asked++; return null; });
    expect(kept['channel'], 'C');
    expect(asked, 0);
    final failed = await withCaptureMeta({'videoId': 'x', 'videoTitle': 'T↗ 1K'}, (_) async => null);
    expect(failed['videoTitle'], 'T');
    expect(failed.containsKey('channel'), isFalse);
  });

  test('oEmbed answers are read; errors come back as null', () async {
    final ok = MockClient((req) async {
      expect(req.url.queryParameters['url'], 'https://www.youtube.com/watch?v=abc');
      return http.Response('{"title":"T","author_name":"Ch"}', 200);
    });
    expect(await fetchYouTubeOembed('abc', client: ok), (title: 'T', channel: 'Ch'));
    expect(await fetchYouTubeOembed('abc', client: MockClient((_) async => http.Response('', 404))), isNull);
  });
}
