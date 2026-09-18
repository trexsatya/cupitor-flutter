import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Ask the user where to put [bytes], then make sure they land there.
///
/// The pickers disagree about who writes the file. Android and iOS take the
/// bytes and write them themselves — they throw if the bytes are missing.
/// macOS, Windows and Linux only return the chosen path and leave the writing
/// to the caller; macOS throws if bytes are passed at all.
///
/// Returns the path the file was written to, or null if the user cancelled.
/// [pickerWrites] overrides the platform choice, for tests.
Future<String?> saveBytesToPickedFile({
  required String dialogTitle,
  required String fileName,
  required Uint8List bytes,
  bool? pickerWrites,
}) async {
  final handOff = pickerWrites ?? (Platform.isAndroid || Platform.isIOS);
  final path = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    bytes: handOff ? bytes : null,
  );
  if (path == null) return null;
  if (!handOff) await File(path).writeAsBytes(bytes);
  return path;
}
