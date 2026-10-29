import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Opens the phone's gallery and returns the chosen picture (already shrunk),
/// or null when nothing was chosen.
typedef AdImagePicker = Future<Uint8List?> Function();

/// The server takes a JPEG, PNG or WebP of up to this many bytes.
const adImageMaxBytes = 600000;

/// Picks from the gallery with the system photo picker (no permission
/// needed), at most 900 px on a side, as a JPEG at quality 80 -- a few
/// hundred KB at most, plenty for a 132 px high banner.
Future<Uint8List?> pickAdImageFromGallery() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 900,
    maxHeight: 900,
    imageQuality: 80,
  );
  return file == null ? null : file.readAsBytes();
}

/// Why [bytes] cannot be used as a Home Ad picture, or null when it can.
/// Checks the file itself (not its name): JPEG, PNG or WebP, within the size
/// the server accepts.
String? adImageProblem(Uint8List bytes) {
  bool starts(List<int> m, [int at = 0]) {
    if (bytes.length < at + m.length) return false;
    for (var i = 0; i < m.length; i++) {
      if (bytes[at + i] != m[i]) return false;
    }
    return true;
  }

  final jpeg = starts(const [0xff, 0xd8, 0xff]);
  final png = starts(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final webp = starts(const [0x52, 0x49, 0x46, 0x46]) && starts(const [0x57, 0x45, 0x42, 0x50], 8);
  if (!jpeg && !png && !webp) return 'Choose a JPEG, PNG or WebP picture.';
  if (bytes.length > adImageMaxBytes) return 'That picture is too large (over 600 KB). Choose a smaller one.';
  return null;
}
