import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

/// Picks a picture from the gallery and makes it a platform logo: the whole
/// logo, kept in proportion, centred on a white 2.4 : 1 tile (the shape the
/// Customer App uses for every platform), as a PNG. The logo's own text and
/// symbols are never cut; only empty white or transparent margins around it
/// are trimmed so the logo fills the tile. The admin uploads the original;
/// no resizing by hand.
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

/// [source] (any picture Flutter can read) with its empty white / transparent
/// margins trimmed, scaled to fit inside a 2.4 : 1 tile on white, centred,
/// nothing of the logo cut, as PNG bytes; null if it cannot be decoded. A
/// heavy picture is given a smaller tile until it is small enough.
Future<Uint8List?> fitLogo(Uint8List source) async {
  try {
    final codec = await ui.instantiateImageCodec(source);
    final image = (await codec.getNextFrame()).image;
    final area = await contentArea(image);
    Uint8List? last;
    for (final (w, h) in logoSizes) {
      final png = await _tile(image, area, w, h);
      if (png == null) return null;
      last = png;
      if (png.length <= logoMaxBytes) break;
    }
    return last;
  } catch (_) {
    return null;
  }
}

/// The part of [image] that holds the logo: the picture without its empty
/// margins. Only when the picture's background is white or transparent (read
/// from its corners); a logo on its own dark or coloured background is kept
/// whole, as is a picture with nothing to trim. A small margin is left.
Future<ui.Rect> contentArea(ui.Image image) async {
  final whole = ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return whole;
  final w = image.width;
  final h = image.height;
  bool background(int x, int y) {
    final i = (y * w + x) * 4;
    final a = data.getUint8(i + 3);
    if (a < 16) return true;
    return data.getUint8(i) > 235 && data.getUint8(i + 1) > 235 && data.getUint8(i + 2) > 235;
  }

  // All four corners must be background, else the picture has its own backdrop.
  if (!(background(0, 0) && background(w - 1, 0) && background(0, h - 1) && background(w - 1, h - 1))) return whole;
  var minX = w, minY = h, maxX = -1, maxY = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (!background(x, y)) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return whole; // nothing but background
  final cw = maxX - minX + 1;
  final ch = maxY - minY + 1;
  if (cw < 4 || ch < 4) return whole; // a speck, not a logo
  final pad = ((cw > ch ? cw : ch) * 0.03).ceil().clamp(2, 1 << 20);
  final left = (minX - pad).clamp(0, w);
  final top = (minY - pad).clamp(0, h);
  final right = (maxX + 1 + pad).clamp(0, w);
  final bottom = (maxY + 1 + pad).clamp(0, h);
  return ui.Rect.fromLTRB(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble());
}

Future<Uint8List?> _tile(ui.Image image, ui.Rect from, int w, int h) async {
  final scale = (w / from.width) < (h / from.height) ? w / from.width : h / from.height;
  final dw = from.width * scale;
  final dh = from.height * scale;
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
