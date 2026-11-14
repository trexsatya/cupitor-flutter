import 'dart:convert';

import 'package:cupitor/local_subtitles.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

class _SubtitlePicker extends FilePicker {
  _SubtitlePicker(this.file);

  final PlatformFile? file;
  late FileType requestedType;
  List<String>? requestedExtensions;
  late bool requestedData;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    requestedType = type;
    requestedExtensions = allowedExtensions;
    requestedData = withData;
    final selected = file;
    return selected == null ? null : FilePickerResult([selected]);
  }
}

void main() {
  const srt =
      '1\r\n00:00:10,250 --> 00:00:12,500\r\nFörsta raden\r\nAndra raden\r\n\r\n'
      '2\r\n00:00:02,000 --> 00:00:04,000\r\n<i>Hej!</i>\r\n';

  test('Android picks Drive SRTs without a MIME filter', () async {
    final file = PlatformFile(
      name: 'episode.SRT',
      size: 78,
      path: '/cache/file_picker/episode.SRT',
      identifier: 'content://drive/document/123',
    );
    final picker = _SubtitlePicker(file);
    FilePicker.platform = picker;

    expect(await pickLocalSubtitleFile(isAndroid: true), same(file));
    expect(picker.requestedType, FileType.any);
    expect(picker.requestedExtensions, isNull);
    expect(picker.requestedData, isFalse);
  });

  test('Android rejects non-SRT files selected in the picker', () async {
    FilePicker.platform = _SubtitlePicker(
      PlatformFile(name: 'episode.mp3', size: 78),
    );

    await expectLater(
      pickLocalSubtitleFile(isAndroid: true),
      throwsFormatException,
    );
  });

  test(
    'other platforms retain the SRT filter and handle cancellation',
    () async {
      final picker = _SubtitlePicker(null);
      FilePicker.platform = picker;

      expect(await pickLocalSubtitleFile(isAndroid: false), isNull);
      expect(picker.requestedType, FileType.custom);
      expect(picker.requestedExtensions, ['srt']);
      expect(picker.requestedData, isTrue);
    },
  );

  test('reads and sorts multiline SRT files with Windows line endings', () {
    expect(parseLocalSrt(srt), [
      {'start': 2.0, 'end': 4.0, 'text': 'Hej!'},
      {'start': 10.25, 'end': 12.5, 'text': 'Första raden\nAndra raden'},
    ]);
  });

  test(
    'accepts unnumbered cues, dot decimals, BOM and positioning metadata',
    () {
      expect(
        parseLocalSrt('\uFEFF01:02:03.5 --> 01:02:05.125 X1:0 X2:100\nHej'),
        [
          {'start': 3723.5, 'end': 3725.125, 'text': 'Hej'},
        ],
      );
    },
  );

  test(
    'drops malformed, empty and backwards cues without losing valid ones',
    () {
      expect(
        parseLocalSrt(
          '1\n00:60:00,000 --> 00:60:02,000\nBad\n\n'
          '2\n00:00:04,000 --> 00:00:02,000\nBackwards\n\n'
          '3\n00:00:02,000 --> 00:00:02,000\nZero\n\n'
          '4\n00:00:00,000 --> 00:00:01,000\n\n$srt\n$srt',
        ),
        hasLength(2),
      );
      expect(parseLocalSrt('not a subtitle file'), isEmpty);
    },
  );

  test('decodes Swedish UTF-8, UTF-16 in either byte order and Latin-1', () {
    const text = 'Räksmörgås 🦋';
    expect(
      decodeLocalSubtitles([0xef, 0xbb, 0xbf, ...utf8.encode(text)]),
      text,
    );
    for (final little in [true, false]) {
      final bytes = <int>[
        if (little) ...[0xff, 0xfe] else ...[0xfe, 0xff],
      ];
      for (final unit in text.codeUnits) {
        bytes.addAll(
          little ? [unit & 0xff, unit >> 8] : [unit >> 8, unit & 0xff],
        );
      }
      expect(decodeLocalSubtitles(bytes), text);
    }
    expect(decodeLocalSubtitles(latin1.encode('Räksmörgås')), 'Räksmörgås');
    expect(() => decodeLocalSubtitles([0xff, 0xfe, 0]), throwsFormatException);
    expect(
      () => decodeLocalSubtitles(List.filled(maxLocalSubtitleBytes + 1, 0)),
      throwsFormatException,
    );
  });

  test(
    'the result bridge encodes arbitrary subtitle text and request identity',
    () {
      final payload = {
        'requestId': 'request-1',
        'lines': [
          {
            'start': 1,
            'end': 2,
            'text': '"; window.injected=true; // <img src=x>',
          },
        ],
      };
      expect(localSubtitleResultJs(payload), contains(jsonEncode(payload)));
      expect(
        localSubtitleResultJs({'requestId': 'request-1', 'cancelled': true}),
        contains('"cancelled":true'),
      );
    },
  );
}
