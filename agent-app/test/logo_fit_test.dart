import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:badal_agent_app/services/logo_picker.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [w] x [h] PNG of one solid colour.
Future<Uint8List> _solid(int w, int h, ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = color);
  final image = await recorder.endRecording().toImage(w, h);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

/// The RGBA of pixel ([x], [y]) in a PNG.
Future<List<int>> _pixel(Uint8List png, int x, int y) async {
  final frame = await (await ui.instantiateImageCodec(png)).getNextFrame();
  final data = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final i = (y * frame.image.width + x) * 4;
  return [data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2), data.getUint8(i + 3)];
}

Future<List<int>> _size(Uint8List png) async {
  final frame = await (await ui.instantiateImageCodec(png)).getNextFrame();
  return [frame.image.width, frame.image.height];
}

void main() {
  const red = ui.Color(0xFFFF0000);

  testWidgets('a wide logo is fitted whole into a square: both ends kept, white above and below', (tester) async {
    await tester.runAsync(() async {
      final out = await squareLogo(await _solid(400, 100, red));
      expect(out, isNotNull);
      expect(await _size(out!), [logoSize, logoSize]);
      final mid = logoSize ~/ 2;
      // The very left and right edges of the logo are there (nothing cut off)...
      expect(await _pixel(out, 1, mid), [255, 0, 0, 255]);
      expect(await _pixel(out, logoSize - 2, mid), [255, 0, 0, 255]);
      // ...and the space above and below is white.
      expect(await _pixel(out, mid, 2), [255, 255, 255, 255]);
      expect(await _pixel(out, mid, logoSize - 3), [255, 255, 255, 255]);
    });
  });

  testWidgets('a tall logo is fitted whole too: white at the sides', (tester) async {
    await tester.runAsync(() async {
      final out = await squareLogo(await _solid(100, 400, red));
      expect(await _size(out!), [logoSize, logoSize]);
      final mid = logoSize ~/ 2;
      expect(await _pixel(out, mid, 1), [255, 0, 0, 255]);
      expect(await _pixel(out, mid, logoSize - 2), [255, 0, 0, 255]);
      expect(await _pixel(out, 2, mid), [255, 255, 255, 255]);
    });
  });

  testWidgets('a square logo fills the square; something that is not a picture gives null', (tester) async {
    await tester.runAsync(() async {
      final out = await squareLogo(await _solid(300, 300, red));
      expect(await _pixel(out!, 1, 1), [255, 0, 0, 255]);
      expect(await _pixel(out, logoSize - 2, logoSize - 2), [255, 0, 0, 255]);
      expect(await squareLogo(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}
