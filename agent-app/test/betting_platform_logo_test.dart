import 'dart:convert';
import 'dart:typed_data';

import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/models/management.dart';
import 'package:badal_agent_app/screens/admin/betting_platforms_screen.dart';
import 'package:badal_agent_app/state/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// A 1 x 1 PNG.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

final _adapter = BettingAdapter.fromJson({
  'adapter': 'cashdeskbot',
  'label': 'CashdeskBot partner API',
  'defaultApiUrl': 'https://partners.servcul.com/CashdeskBotAPI',
  'fields': [
    {'key': 'login', 'label': 'Login / Username', 'required': true, 'secret': false},
  ],
});

BettingPlatform _platform({bool builtIn = false, String? logo}) => BettingPlatform.fromJson({
      'method': 'wowbet', 'name': 'wowbet', 'adapter': 'cashdeskbot', 'builtIn': builtIn, 'active': false,
      'status': 'not_configured', 'logo': logo,
    });

class _FakeApi extends AgentApi {
  final calls = <String>[];

  @override
  Future<BettingPlatform> setBettingPlatformLogo(String method, Uint8List? logo) async {
    calls.add('logo $method ${logo == null ? 'removed' : '${logo.length} bytes'}');
    return _platform(logo: logo == null ? null : base64Encode(logo));
  }
}

late _FakeApi _api;

Widget _screen(BettingPlatform p, {Future<Uint8List?> Function()? pick}) {
  _api = _FakeApi();
  final api = _api;
  return ChangeNotifierProvider(
    create: (_) => Session(api: api),
    child: MaterialApp(
      home: BettingPlatformScreen(
        method: 'wowbet',
        adapter: _adapter,
        initial: p,
        pickLogo: pick ?? () async => base64Decode(_png),
      ),
    ),
  );
}

void main() {
  testWidgets('an added platform without a logo: Choose logo sends the picked picture and shows it', (tester) async {
    await tester.pumpWidget(_screen(_platform()));
    expect(find.byKey(const Key('platform-logo-card')), findsOneWidget);
    expect(find.byKey(const Key('platform-logo-preview')), findsNothing);
    expect(find.text('Choose logo'), findsOneWidget);
    await tester.tap(find.byKey(const Key('platform-logo-choose')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['logo wowbet ${base64Decode(_png).length} bytes']);
    expect(find.byKey(const Key('platform-logo-preview')), findsOneWidget);
    expect(find.text('Change logo'), findsOneWidget);
    expect(find.byKey(const Key('platform-logo-remove')), findsOneWidget);
  });

  testWidgets('Remove takes the logo off again', (tester) async {
    await tester.pumpWidget(_screen(_platform(logo: _png)));
    expect(find.byKey(const Key('platform-logo-preview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('platform-logo-remove')));
    await tester.pumpAndSettle();
    expect(_api.calls, ['logo wowbet removed']);
    expect(find.byKey(const Key('platform-logo-preview')), findsNothing);
  });

  testWidgets('nothing picked: nothing is sent', (tester) async {
    await tester.pumpWidget(_screen(_platform(), pick: () async => null));
    await tester.tap(find.byKey(const Key('platform-logo-choose')));
    await tester.pumpAndSettle();
    expect(_api.calls, isEmpty);
    expect(find.textContaining('No picture was chosen'), findsOneWidget);
  });

  testWidgets('a picker that fails is told, nothing is sent', (tester) async {
    await tester.pumpWidget(_screen(_platform(), pick: () async => throw Exception('no gallery')));
    await tester.tap(find.byKey(const Key('platform-logo-choose')));
    await tester.pumpAndSettle();
    expect(_api.calls, isEmpty);
    expect(find.textContaining('Could not open the gallery'), findsOneWidget);
  });

  testWidgets('a built-in platform keeps its own logo: no logo card', (tester) async {
    await tester.pumpWidget(_screen(_platform(builtIn: true)));
    expect(find.byKey(const Key('platform-logo-card')), findsNothing);
  });

  test('an unreadable logo from the server is ignored', () {
    expect(_platform(logo: '!!not base64!!').logo, isNull);
    expect(_platform(logo: _png).logo, isNotNull);
    expect(_platform().logo, isNull);
  });
}
