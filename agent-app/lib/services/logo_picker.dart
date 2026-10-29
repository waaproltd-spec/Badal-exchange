import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

/// Picks a picture from the gallery and makes it a platform logo: the centre
/// square, 128 x 128, as a PNG (a few KB; the server accepts up to 60 KB).
/// Returns null when nothing was picked or the picture cannot be read.
typedef LogoPicker = Future<Uint8List?> Function();

const logoSize = 128;

Future<Uint8List?> pickLogoFromGallery() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
  if (file == null) return null;
  return squareLogo(await file.readAsBytes());
}

/// The centre square of [source] (any picture Flutter can read), scaled to
/// [logoSize], as PNG bytes; null if it cannot be decoded.
Future<Uint8List?> squareLogo(Uint8List source) async {
  try {
    final codec = await ui.instantiateImageCodec(source);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final side = image.width < image.height ? image.width : image.height;
    final from = ui.Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side.toDouble(), side.toDouble());
    final to = ui.Rect.fromLTWH(0, 0, logoSize.toDouble(), logoSize.toDouble());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder, to).drawImageRect(image, from, to, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final out = await recorder.endRecording().toImage(logoSize, logoSize);
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
