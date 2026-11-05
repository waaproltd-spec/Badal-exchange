import 'dart:convert';

import 'package:badal_exchange_customer/models/app_content.dart';
import 'package:badal_exchange_customer/widgets/home_ads_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A 1 x 1 PNG, as the server sends a picture chosen from a manager's gallery.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

HomeAd _ad(String id, {String? image, String? imageUrl}) =>
    HomeAd.fromJson({'id': id, 'title': 'Ad $id', 'body': null, 'imageUrl': imageUrl, 'image': image, 'linkUrl': null});

Widget _strip(List<HomeAd> ads) => MaterialApp(home: Scaffold(body: HomeAdsStrip(ads: ads)));

void main() {
  test('an ad carries the picture the server sent, decoded', () {
    expect(_ad('1', image: _png).image, base64Decode(_png));
    expect(_ad('1').image, isNull);
    expect(_ad('1', image: '').image, isNull);
    expect(_ad('1', image: '!!not base64!!').image, isNull, reason: 'a bad picture never breaks the ad');
  });

  testWidgets('a picture from the gallery is shown in the ad', (tester) async {
    await tester.pumpWidget(_strip([_ad('1', image: _png)]));
    await tester.pump();
    expect(find.byKey(const Key('home-ad-image-1')), findsOneWidget);
    expect(find.text('Ad 1'), findsOneWidget);
  });

  testWidgets('an ad without a picture still shows its text (the image is optional)', (tester) async {
    await tester.pumpWidget(_strip([_ad('2')]));
    await tester.pump();
    expect(find.byKey(const Key('home-ad-image-2')), findsNothing);
    expect(find.text('Ad 2'), findsOneWidget);
  });
}
