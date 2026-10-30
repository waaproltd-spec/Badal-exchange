import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

/// Picks a picture from the gallery and makes it a platform logo, as a PNG on
/// the 2.4 : 1 tile the Customer App uses for every platform:
///  - the whole logo, kept in proportion, centred, with the same small margin
///    on every side (it never touches the edge, so nothing is cut);
///  - empty white / transparent space around it is removed so it fills the tile;
///  - a logo that is a coloured badge (e.g. white letters on black) on a white
///    page fills the whole tile with the badge's colour, like the built-in
///    dark logos, and its lettering is made as large as the tile allows.
/// The admin uploads the original; no resizing by hand.
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

/// [source] (any picture Flutter can read) as the tile described above, PNG
/// bytes; null if it cannot be decoded. A heavy picture is given a smaller
/// tile until it is small enough.
Future<Uint8List?> fitLogo(Uint8List source) async {
  try {
    final codec = await ui.instantiateImageCodec(source);
    final image = (await codec.getNextFrame()).image;
    final plan = await planLogo(image);
    Uint8List? last;
    for (final (w, h) in logoSizes) {
      final png = await _tile(image, plan, w, h);
      if (png == null) return null;
      last = png;
      if (png.length <= logoMaxBytes) break;
    }
    return last;
  } catch (_) {
    return null;
  }
}

/// What to draw: the [source] part of the picture, on a [background] tile.
class LogoPlan {
  const LogoPlan(this.source, this.background);
  final ui.Rect source;
  final ui.Color background;
}

const _white = ui.Color(0xFFFFFFFF);

/// The margin kept on every side of the logo in a tile [tileHeight] high.
int logoMargin(int tileHeight) => (tileHeight * 0.09).round().clamp(2, 24).toInt();

/// Finds the logo in [image]: the picture without the white / transparent page
/// around it (the page is found from the picture's edge, so white letters
/// inside a dark badge are never mistaken for page). When the logo is a solid
/// badge on that page, the badge's colour becomes the tile's background and
/// only its lettering is kept, so it can be drawn large.
Future<LogoPlan> planLogo(ui.Image image) async {
  final w = image.width;
  final h = image.height;
  final whole = LogoPlan(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), _white);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return whole;
  final px = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  bool white(int p) {
    final i = p * 4;
    return px[i + 3] < 16 || (px[i] > 235 && px[i + 1] > 235 && px[i + 2] > 235);
  }

  // The page: white / transparent pixels connected to the picture's edge.
  final outside = Uint8List(w * h);
  final queue = Int32List(w * h);
  var head = 0, tail = 0;
  void push(int p) {
    if (outside[p] == 0 && white(p)) {
      outside[p] = 1;
      queue[tail++] = p;
    }
  }

  for (var x = 0; x < w; x++) {
    push(x);
    push((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    push(y * w);
    push(y * w + w - 1);
  }
  while (head < tail) {
    final p = queue[head++];
    final x = p % w, y = p ~/ w;
    if (x > 0) push(p - 1);
    if (x < w - 1) push(p + 1);
    if (y > 0) push(p - w);
    if (y < h - 1) push(p + w);
  }

  // The logo's box: everything that is not page.
  var minX = w, minY = h, maxX = -1, maxY = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (outside[y * w + x] == 0) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return whole; // nothing but page
  final bw = maxX - minX + 1;
  final bh = maxY - minY + 1;
  if (bw < 4 || bh < 4) return whole; // a speck, not a logo
  final plain = LogoPlan(ui.Rect.fromLTRB(minX.toDouble(), minY.toDouble(), (maxX + 1).toDouble(), (maxY + 1).toDouble()), _white);

  // A badge: the logo's edge is one solid, non-white colour all round.
  final shorter = bw < bh ? bw : bh;
  var inset = (3 + 0.02 * shorter).round();
  if (inset > shorter ~/ 2 - 1) inset = shorter ~/ 2 - 1;
  if (inset < 1) inset = 1;
  final samples = <int>[];
  final xa = minX + (bw * 0.2).floor(), xb = minX + (bw * 0.8).ceil();
  final ya = minY + (bh * 0.2).floor(), yb = minY + (bh * 0.8).ceil();
  for (var x = xa; x <= xb && x <= maxX; x++) {
    samples..add((minY + inset) * w + x)..add((maxY - inset) * w + x);
  }
  for (var y = ya; y <= yb && y <= maxY; y++) {
    samples..add(y * w + minX + inset)..add(y * w + maxX - inset);
  }
  var count = 0, sr = 0, sg = 0, sb = 0;
  for (final p in samples) {
    final i = p * 4;
    if (outside[p] == 0 && px[i + 3] >= 200) {
      count++;
      sr += px[i];
      sg += px[i + 1];
      sb += px[i + 2];
    }
  }
  if (samples.isEmpty || count < samples.length * 0.85) return plain;
  final cr = sr ~/ count, cg = sg ~/ count, cb = sb ~/ count;
  if (cr > 235 && cg > 235 && cb > 235) return plain;
  var close = 0;
  for (final p in samples) {
    final i = p * 4;
    if (outside[p] == 0 && px[i + 3] >= 200 && (px[i] - cr).abs() + (px[i + 1] - cg).abs() + (px[i + 2] - cb).abs() <= 45) close++;
  }
  if (close < samples.length * 0.85) return plain;

  // Keep only the lettering: away from the page's edge (its rounded corners
  // and soft rim), whatever differs from the badge colour.
  var near = outside;
  for (var r = 0; r < 3; r++) {
    final next = Uint8List.fromList(near);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = y * w + x;
        if (near[p] == 1) continue;
        if ((x > 0 && near[p - 1] == 1) || (x < w - 1 && near[p + 1] == 1) || (y > 0 && near[p - w] == 1) || (y < h - 1 && near[p + w] == 1)) {
          next[p] = 1;
        }
      }
    }
    near = next;
  }
  var fx0 = w, fy0 = h, fx1 = -1, fy1 = -1;
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      final p = y * w + x;
      if (near[p] == 1) continue;
      final i = p * 4;
      if (px[i + 3] < 16) continue;
      if ((px[i] - cr).abs() + (px[i + 1] - cg).abs() + (px[i + 2] - cb).abs() > 90) {
        if (x < fx0) fx0 = x;
        if (x > fx1) fx1 = x;
        if (y < fy0) fy0 = y;
        if (y > fy1) fy1 = y;
      }
    }
  }
  if (fx1 - fx0 < 3 || fy1 - fy0 < 3) return plain; // nothing but one colour
  final lettering = ui.Rect.fromLTRB(
      (fx0 - 1).clamp(0, w).toDouble(), (fy0 - 1).clamp(0, h).toDouble(), (fx1 + 2).clamp(0, w).toDouble(), (fy1 + 2).clamp(0, h).toDouble());
  return LogoPlan(lettering, ui.Color.fromARGB(255, cr, cg, cb));
}

Future<Uint8List?> _tile(ui.Image image, LogoPlan plan, int w, int h) async {
  final m = logoMargin(h);
  final from = plan.source;
  final scale = ((w - 2 * m) / from.width) < ((h - 2 * m) / from.height) ? (w - 2 * m) / from.width : (h - 2 * m) / from.height;
  final dw = from.width * scale;
  final dh = from.height * scale;
  final to = ui.Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh);
  final tile = ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, tile);
  canvas.drawRect(tile, ui.Paint()..color = plan.background);
  canvas.drawImageRect(image, from, to, ui.Paint()..filterQuality = ui.FilterQuality.high);
  final out = await recorder.endRecording().toImage(w, h);
  final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
}
