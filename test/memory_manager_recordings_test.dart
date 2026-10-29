import 'dart:io';

// Mock the platform used by the app's audioplayers dependency; no microphone
// or speaker is opened during this navigation/import regression.
// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:cupitor/db.dart';
import 'package:cupitor/memory_manager.dart';
import 'package:cupitor/recording_transfer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _QuietPlayer extends Fake implements AudioplayersPlatformInterface {
  @override
  Future<void> create(String id) async {}
  @override
  Future<void> dispose(String id) async {}
  @override
  Future<void> release(String id) async {}
  @override
  Future<void> stop(String id) async {}
  @override
  Stream<AudioEvent> getEventStream(String id) => const Stream.empty();
}

class _QuietGlobal extends Fake implements GlobalAudioplayersPlatformInterface {
  @override
  Future<void> init() async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
}

class _BundlePicker extends FilePicker {
  _BundlePicker(this.bytes);
  final Uint8List bytes;
  int calls = 0;
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
    calls++;
    return FilePickerResult([
      PlatformFile(name: 'recordings.zip', size: bytes.length, bytes: bytes),
    ]);
  }
}

Future<void> waitFor(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
  expect(finder, findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _BundlePicker picker;
  late AudioplayersPlatformInterface oldPlayer;
  late GlobalAudioplayersPlatformInterface oldGlobal;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('cupitor-empty-recordings-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    oldPlayer = AudioplayersPlatformInterface.instance;
    oldGlobal = GlobalAudioplayersPlatformInterface.instance;
    AudioplayersPlatformInterface.instance = _QuietPlayer();
    GlobalAudioplayersPlatformInterface.instance = _QuietGlobal();
    final source = await Directory('${temp.path}/source').create();
    await File('${source.path}/imported-clip.m4a').writeAsBytes([1, 2, 3]);
    picker = _BundlePicker(
      await RecordingTransfer.exportBundle(
        directory: source,
        names: ['imported-clip.m4a'],
      ),
    );
    FilePicker.platform = picker;
  });
  tearDownAll(() async {
    AudioplayersPlatformInterface.instance = oldPlayer;
    GlobalAudioplayersPlatformInterface.instance = oldGlobal;
    await (await CupitorDb.instance.rawDb())?.close();
    await temp.delete(recursive: true);
  });

  testWidgets(
    'zero clips can open Voice recordings, import a bundle and refresh the storage count',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MemoryManagerScreen()));
      await waitFor(tester, find.text('0 clip(s) from manual cards'));
      final voice = find.ancestor(
        of: find.text('Voice recordings'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(voice).onTap, isNotNull);
      await tester.tap(voice);
      await waitFor(tester, find.text('No voice recordings on this device.'));
      final import = find.byTooltip('Import recordings');
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.file_upload_outlined),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(import);
      await waitFor(tester, find.text('imported-clip.m4a'));
      expect(picker.calls, 1);
      expect(
        await tester.runAsync(
          () =>
              File('${temp.path}/manual_audio/imported-clip.m4a').readAsBytes(),
        ),
        [1, 2, 3],
      );
      await tester.pageBack();
      await waitFor(tester, find.text('1 clip(s) from manual cards'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
