import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/models/console.dart';
import 'package:badal_agent_app/screens/manage_screens.dart';
import 'package:badal_agent_app/services/ad_image_picker.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// A 1 x 1 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';
final _bytes = base64Decode(_png);

HomeAd _ad({String? image, String? imageUrl}) => HomeAd.fromJson({
      'id': 'ad1', 'title': 'Welcome', 'body': 'Hello', 'imageUrl': imageUrl, 'image': image,
      'linkUrl': null, 'enabled': true, 'sortOrder': 0,
    });

class _FakeApi extends AgentApi {
  final saves = <Map<String, Object?>>[];
  Completer<void>? hold;
  Object? failWith;

  @override
  Future<void> saveHomeAd({
    String? id,
    required String title,
    String? body,
    String? imageUrl,
    String? linkUrl,
    required bool enabled,
    int sortOrder = 0,
    Uint8List? image,
    bool removeImage = false,
  }) async {
    if (hold != null) await hold!.future;
    final err = failWith;
    if (err != null) throw err;
    saves.add({'id': id, 'title': title, 'imageUrl': imageUrl, 'image': image?.length, 'remove': removeImage});
  }
}

late _FakeApi _api;
bool? _result;

Future<void> _open(WidgetTester tester, {HomeAd? ad, Future<Uint8List?> Function()? pick}) async {
  _api = _FakeApi();
  _result = null;
  final api = _api;
  // Tall enough that the whole form (with the picture) is built and Save is on screen.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => Session(api: api),
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const Key('open'),
            onPressed: () async {
              _result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => HomeAdForm(ad: ad, pickImage: pick ?? () async => _bytes)),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

Future<void> _fillTitle(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).first, 'Welcome');
}

void main() {
  testWidgets('the manual image link is gone; Choose Image takes its place', (tester) async {
    await _open(tester);
    expect(find.text('Image link (optional)'), findsNothing);
    expect(find.text('Choose Image'), findsOneWidget);
    expect(find.byKey(const Key('ad-image-preview')), findsNothing);
  });

  testWidgets('choose, preview, save: the picture is uploaded with the ad and the states are shown', (tester) async {
    await _open(tester);
    await _fillTitle(tester);
    await tester.tap(find.byKey(const Key('ad-image-choose')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ad-image-preview')), findsOneWidget);
    expect(find.text('Change Image'), findsOneWidget);
    expect(_api.saves, isEmpty, reason: 'nothing is sent until Save');

    _api.hold = Completer<void>();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Uploading…'), findsOneWidget);
    _api.hold!.complete();
    await tester.pump();
    expect(find.text('Upload successful'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_api.saves, [
      {'id': null, 'title': 'Welcome', 'imageUrl': null, 'image': _bytes.length, 'remove': false},
    ]);
    expect(_result, true, reason: 'the form closes after a successful upload');
  });

  testWidgets('a failed upload keeps the form, says so, and a retry works', (tester) async {
    await _open(tester, ad: _ad(image: _png));
    _api.failWith = const ApiException(statusCode: 500, code: 'X', message: 'Server unavailable');
    await tester.tap(find.byKey(const Key('ad-image-choose')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Upload failed'), findsOneWidget);
    expect(find.textContaining('previous picture are unchanged'), findsOneWidget);
    expect(find.byType(HomeAdForm), findsOneWidget);
    expect(_api.saves, isEmpty);

    _api.failWith = null;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.saves.single['image'], _bytes.length);
    expect(_result, true);
  });

  testWidgets('editing without choosing a new picture sends none (the saved one stays)', (tester) async {
    await _open(tester, ad: _ad(image: _png));
    expect(find.byKey(const Key('ad-image-preview')), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.saves.single['image'], isNull);
    expect(_api.saves.single['remove'], false);
  });

  testWidgets('Remove takes the picture off; the image stays optional', (tester) async {
    await _open(tester, ad: _ad(image: _png));
    await tester.tap(find.byKey(const Key('ad-image-remove')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ad-image-preview')), findsNothing);
    expect(find.text('Choose Image'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.saves.single['remove'], true);
    expect(_api.saves.single['image'], isNull);
  });

  testWidgets('a new ad with no picture saves fine', (tester) async {
    await _open(tester);
    await _fillTitle(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_api.saves.single['image'], isNull);
    expect(_result, true);
  });

  testWidgets('a file that is not a JPEG, PNG or WebP, or is too large, is refused before upload', (tester) async {
    await _open(tester, pick: () async => Uint8List.fromList(utf8.encode('this is text, not a picture')));
    await tester.tap(find.byKey(const Key('ad-image-choose')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a JPEG, PNG or WebP picture.'), findsOneWidget);
    expect(find.byKey(const Key('ad-image-preview')), findsNothing);
  });

  test('adImageProblem: formats and size', () {
    expect(adImageProblem(_bytes), isNull);
    expect(adImageProblem(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 1])), isNull);
    final webp = Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0]);
    expect(adImageProblem(webp), isNull);
    expect(adImageProblem(Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), isNotNull, reason: 'GIF');
    expect(adImageProblem(Uint8List(0)), isNotNull);
    final big = Uint8List(adImageMaxBytes + 1)..setAll(0, [0xff, 0xd8, 0xff]);
    expect(adImageProblem(big), contains('too large'));
  });
}
