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

/// [w] x [h] picture: [bg] page, then each ([color], x, y, w, h) rectangle in order.
Future<Uint8List> _paint(int w, int h, ui.Color bg, List<(ui.Color, int, int, int, int)> rects) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = bg);
  for (final (c, x, y, rw, rh) in rects) {
    canvas.drawRect(ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), rw.toDouble(), rh.toDouble()), ui.Paint()..color = c);
  }
  final image = await recorder.endRecording().toImage(w, h);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  const red = ui.Color(0xFFFF0000);
  const white = ui.Color(0xFFFFFFFF);
  const black = ui.Color(0xFF000000);
  final (tw, th) = logoSizes.first;
  final m = logoMargin(th);
  const pw = [255, 255, 255, 255];
  const pr = [255, 0, 0, 255];
  const pk = [0, 0, 0, 255];

  testWidgets('a wide logo is fitted whole into the 2.4 : 1 tile: equal margin at both ends, white above and below', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(400, 100, red));
      expect(out, isNotNull);
      expect(await _size(out!), [tw, th], reason: 'the 2.4 : 1 tile');
      expect(tw / th, closeTo(2.4, 0.01));
      final midY = th ~/ 2;
      expect(await _pixel(out, m + 2, midY), pr, reason: 'the logo starts one margin in...');
      expect(await _pixel(out, tw - m - 3, midY), pr, reason: '...and ends one margin before the right edge');
      expect(await _pixel(out, 2, midY), pw);
      expect(await _pixel(out, tw - 3, midY), pw);
      expect(await _pixel(out, tw ~/ 2, 2), pw);
      expect(await _pixel(out, tw ~/ 2, th - 3), pw);
    });
  });

  testWidgets('a tall logo is fitted whole too: margin top and bottom, white at the sides', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(100, 400, red));
      expect(await _size(out!), [tw, th]);
      final midX = tw ~/ 2;
      expect(await _pixel(out, midX, m + 2), pr);
      expect(await _pixel(out, midX, th - m - 3), pr);
      expect(await _pixel(out, midX, 2), pw);
      expect(await _pixel(out, midX, th - 3), pw);
      expect(await _pixel(out, 2, th ~/ 2), pw);
      expect(await _pixel(out, tw - 3, th ~/ 2), pw);
    });
  });

  testWidgets('a logo of the tile\'s own shape keeps its margin too; something that is not a picture gives null', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(600, 250, red));
      expect(await _size(out!), [tw, th]);
      expect(await _pixel(out, tw ~/ 2, m + 2), pr);
      expect(await _pixel(out, tw ~/ 2, th - m - 3), pr);
      expect(await _pixel(out, 1, 1), pw);
      expect(await fitLogo(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  testWidgets('empty white space around a small logo is removed so it fills the tile, margin all round', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _paint(1000, 600, white, [(red, 450, 290, 100, 20)]));
      expect(await _size(out!), [tw, th]);
      expect(await _pixel(out, m + 3, th ~/ 2), pr, reason: 'fills the width, one margin in');
      expect(await _pixel(out, tw - m - 4, th ~/ 2), pr);
      expect(await _pixel(out, 2, th ~/ 2), pw);
      expect(await _pixel(out, tw - 3, th ~/ 2), pw);
    });
  });

  testWidgets('a logo that touches the picture\'s own right edge still gets its margin there', (tester) async {
    await tester.runAsync(() async {
      // Like LuckyPari: the lettering runs right up to the edge of the file.
      final out = await fitLogo(await _paint(400, 200, white, [(red, 100, 80, 300, 40)]));
      final midY = th ~/ 2;
      expect(await _pixel(out!, tw - 3, midY), pw, reason: 'never flush with the tile edge');
      expect(await _pixel(out, tw - m - 4, midY), pr);
      expect(await _pixel(out, m + 3, midY), pr);
      expect(await _pixel(out, 2, midY), pw);
    });
  });

  testWidgets('a badge on a white page (white letters on black) fills the whole tile; the letters are large and centred', (tester) async {
    await tester.runAsync(() async {
      // A 5 : 1 black badge with white lettering, on a big white page.
      final out = await fitLogo(await _paint(1000, 500, white, [(black, 100, 170, 800, 160), (white, 350, 230, 300, 40)]));
      expect(await _size(out!), [tw, th]);
      final midY = th ~/ 2;
      expect(await _pixel(out, 1, 1), pk, reason: 'no white page above, below or at the corners');
      expect(await _pixel(out, tw - 2, th - 2), pk);
      expect(await _pixel(out, 1, th - 2), pk);
      expect(await _pixel(out, 2, midY), pk);
      // The white lettering spans the tile apart from its margins.
      expect(await _pixel(out, m + 3, midY), pw);
      expect(await _pixel(out, tw - m - 4, midY), pw);
      expect(await _pixel(out, m ~/ 2, midY), pk, reason: 'a margin of badge colour round the lettering');
    });
  });

  testWidgets('a logo on its own dark background (the whole picture) is kept: the tile takes that colour', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _paint(600, 250, black, [(white, 250, 100, 100, 50)]));
      expect(await _size(out!), [tw, th]);
      expect(await _pixel(out, 1, 1), pk, reason: 'the dark backdrop stays');
      expect(await _pixel(out, tw ~/ 2, th ~/ 2), pw);
    });
  });

  testWidgets('an all-white picture is not a crash: it comes out as a white tile', (tester) async {
    await tester.runAsync(() async {
      final out = await fitLogo(await _solid(300, 200, white));
      expect(await _size(out!), [tw, th]);
      expect(await _pixel(out, tw ~/ 2, th ~/ 2), pw);
    });
  });
}
