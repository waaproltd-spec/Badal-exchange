import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

/// Picks a picture from the gallery and makes it a platform logo: the whole
/// picture, kept in proportion, centred on a white 128 x 128 square, as a PNG
/// (a few KB; the server accepts up to 60 KB). A wide logo such as
/// "LuckyPari" is shown in full, not cut at the sides.
/// Returns null when nothing was picked or the picture cannot be read.
typedef LogoPicker = Future<Uint8List?> Function();

const logoSize = 128;

Future<Uint8List?> pickLogoFromGallery() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
  if (file == null) return null;
  return squareLogo(await file.readAsBytes());
}

/// [source] (any picture Flutter can read) scaled to fit inside a [logoSize]
/// square on white, nothing cropped, as PNG bytes; null if it cannot be decoded.
Future<Uint8List?> squareLogo(Uint8List source) async {
  try {
    final codec = await ui.instantiateImageCodec(source);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final from = ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final scale = logoSize / (image.width > image.height ? image.width : image.height);
    final w = image.width * scale;
    final h = image.height * scale;
    final to = ui.Rect.fromLTWH((logoSize - w) / 2, (logoSize - h) / 2, w, h);
    final square = ui.Rect.fromLTWH(0, 0, logoSize.toDouble(), logoSize.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, square);
    canvas.drawRect(square, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
    canvas.drawImageRect(image, from, to, ui.Paint()..filterQuality = ui.FilterQuality.high);
    final out = await recorder.endRecording().toImage(logoSize, logoSize);
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
