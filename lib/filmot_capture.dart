import 'dart:convert';

/// Accepts the dialog bridge's object and the native browsers' JSON text.
/// Android can wrap the text in a second JSON string.
Map<String, dynamic>? decodeFilmotCapture(Object? raw) {
  var value = raw;
  try {
    for (var layer = 0; layer < 2 && value is String; layer++) {
      value = jsonDecode(value);
    }
  } on FormatException {
    return null;
  }
  if (value is! Map<String, dynamic>) return null;
  final lines = value['lines'];
  if (lines is! List || lines.any((line) => line is! Map<String, dynamic>)) {
    return null;
  }
  return value;
}
