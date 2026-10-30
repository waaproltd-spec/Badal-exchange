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
  final (tw, th) = logoSizes.first;

  testWidgets('a wide logo is fitted whole into the 2.4 : 1 tile: both ends kept, white above and below', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(400, 100, red));
      expect(out, isNotNull);
      expect(await _size(out!), [tw, th], reason: 'the 2.4 : 1 tile');
      expect(tw / th, closeTo(2.4, 0.01));
      final midY = th ~/ 2;
      // A 4 : 1 logo is wider than the tile: both ends are there, nothing cut off...
      expect(await _pixel(out, 1, midY), [255, 0, 0, 255]);
      expect(await _pixel(out, tw - 2, midY), [255, 0, 0, 255]);
      // ...and the space above and below is white.
      expect(await _pixel(out, tw ~/ 2, 2), [255, 255, 255, 255]);
      expect(await _pixel(out, tw ~/ 2, th - 3), [255, 255, 255, 255]);
    });
  });

  testWidgets('a tall logo is fitted whole too: white at the sides', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(100, 400, red));
      expect(await _size(out!), [tw, th]);
      final midX = tw ~/ 2;
      // Top and bottom of the tall logo are there; white at the sides.
      expect(await _pixel(out, midX, 1), [255, 0, 0, 255]);
      expect(await _pixel(out, midX, th - 2), [255, 0, 0, 255]);
      expect(await _pixel(out, 2, th ~/ 2), [255, 255, 255, 255]);
      expect(await _pixel(out, tw - 3, th ~/ 2), [255, 255, 255, 255]);
    });
  });

  testWidgets('a logo of the tile\'s own shape fills it; something that is not a picture gives null', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(600, 250, red));
      expect(await _size(out!), [tw, th]);
      expect(await _pixel(out, 1, 1), [255, 0, 0, 255]);
      expect(await _pixel(out, tw - 2, th - 2), [255, 0, 0, 255]);
      expect(await fitLogo(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  /// A [w] x [h] picture of [bg] with a [fg] rectangle ([rx], [ry], [rw], [rh]).
  Future<Uint8List> compose(int w, int h, ui.Color bg, ui.Color fg, int rx, int ry, int rw, int rh) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = bg);
    canvas.drawRect(ui.Rect.fromLTWH(rx.toDouble(), ry.toDouble(), rw.toDouble(), rh.toDouble()), ui.Paint()..color = fg);
    final image = await recorder.endRecording().toImage(w, h);
    return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  testWidgets('empty white margins are trimmed so the logo fills the tile, all of it kept', (tester) async {
    await tester.runAsync(() async {
      // A small wide logo in the middle of a big white picture.
      final out = await fitLogo(await compose(1000, 600, const ui.Color(0xFFFFFFFF), red, 450, 290, 100, 20));
      expect(await _size(out!), [tw, th]);
      // The logo now spans nearly the whole tile width (without trimming it would be ~29 px wide).
      expect(await _pixel(out, 14, th ~/ 2), [255, 0, 0, 255]);
      expect(await _pixel(out, tw - 15, th ~/ 2), [255, 0, 0, 255]);
      // A thin white margin is left around it.
      expect(await _pixel(out, 2, th ~/ 2), [255, 255, 255, 255]);
    });
  });

  testWidgets('a logo on its own dark background is not trimmed (its backdrop is part of it)', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await compose(600, 250, const ui.Color(0xFF000000), const ui.Color(0xFFFFFFFF), 250, 100, 100, 50));
      expect(await _size(out!), [tw, th]);
      expect(await _pixel(out, 1, 1), [0, 0, 0, 255], reason: 'the dark backdrop stays');
      expect(await _pixel(out, tw ~/ 2, th ~/ 2), [255, 255, 255, 255]);
    });
  });

  testWidgets('an all-white picture is not a crash: it comes out as a white tile', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(300, 200, const ui.Color(0xFFFFFFFF)));
      expect(await _size(out!), [tw, th]);
      expect(await _pixel(out, tw ~/ 2, th ~/ 2), [255, 255, 255, 255]);
    });
  });
}
