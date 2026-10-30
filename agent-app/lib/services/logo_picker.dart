import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

/// Picks a picture from the gallery and makes it a platform logo: the whole
/// picture, kept in proportion, centred on a white 2.4 : 1 tile (the shape the
/// Customer App uses for every platform), as a PNG. Nothing is cropped, so a
/// logo's text and symbols are always complete. The admin uploads the
/// original; no resizing by hand.
/// Returns null when nothing was picked or the picture cannot be read.
typedef LogoPicker = Future<Uint8List?> Function();

/// Tile sizes tried from the sharpest down; the first PNG within
/// [logoMaxBytes] is used (the server accepts up to 60 KB).
const logoSizes = [(288, 120), (240, 100), (192, 80), (144, 60)];
const logoMaxBytes = 55000;

Future<Uint8List?> pickLogoFromGallery() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
  if (file == null) return null;
  return fitLogo(await file.readAsBytes());
}

/// [source] (any picture Flutter can read) scaled to fit inside a 2.4 : 1
/// tile on white, centred, nothing cropped, as PNG bytes; null if it cannot
/// be decoded. A heavy picture is given a smaller tile until it is small enough.
Future<Uint8List?> fitLogo(Uint8List source) async {
  try {
    final codec = await ui.instantiateImageCodec(source);
    final image = (await codec.getNextFrame()).image;
    Uint8List? last;
    for (final (w, h) in logoSizes) {
      final png = await _tile(image, w, h);
      if (png == null) return null;
      last = png;
      if (png.length <= logoMaxBytes) break;
    }
    return last;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _tile(ui.Image image, int w, int h) async {
  final from = ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
  final scale = (w / image.width) < (h / image.height) ? w / image.width : h / image.height;
  final dw = image.width * scale;
  final dh = image.height * scale;
  final to = ui.Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh);
  final tile = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, tile);
  canvas.drawRect(tile, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  canvas.drawImageRect(image, from, to, ui.Paint()..filterQuality = ui.FilterQuality.high);
  final out = await recorder.endRecording().toImage(w, h);
  final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
}
