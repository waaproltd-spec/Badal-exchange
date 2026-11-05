// The language setting: every screen text has its Somali (and the few texts
// first written in Somali their English), the setting is kept on the phone,
// and the texts change at once.
import 'dart:io';

import 'package:badal_agent_app/l10n/english.dart';
import 'package:badal_agent_app/l10n/language.dart';
import 'package:badal_agent_app/l10n/somali.dart';
import 'package:badal_agent_app/l10n/tr.dart';
import 'package:badal_agent_app/l10n/wallet_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reads the string literals written next to each other starting at [i].
(String, int)? _literals(String src, int i) {
  final out = StringBuffer();
  var j = i;
  var any = false;
  while (true) {
    var k = j;
    while (k < src.length && ' \t\r\n'.contains(src[k])) {
      k++;
    }
    if (k >= src.length || (src[k] != "'" && src[k] != '"')) break;
    final q = src[k];
    k++;
    while (k < src.length && src[k] != q) {
      if (src[k] == r'\') {
        k++;
        final c = src[k];
        out.write(switch (c) {
          'n' => '\n',
          't' => '\t',
          _ => c,
        });
        // An escaped dollar sign is a real $ in the text.
      } else if (src[k] == r'$' && k + 1 < src.length && (src[k + 1] == '{' || RegExp(r'[A-Za-z_]').hasMatch(src[k + 1]))) {
        return null; // an interpolation: not a plain text
      } else {
        out.write(src[k]);
      }
      k++;
    }
    j = k + 1;
    any = true;
  }
  return any ? (out.toString(), j) : null;
}

/// Every plain text the app passes to tr( / trp( / Tx(, and the plain texts inside Tx( x ? 'a' : 'b' ).
Map<String, String> _usedTexts() {
  final found = <String, String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
    if (f.path.contains('/l10n/')) continue;
    final src = f.readAsStringSync();
    for (final m in RegExp(r'(?<![\w.$])(tr|trp|Tx)\(').allMatches(src)) {
      final lit = _literals(src, m.end);
      if (lit != null) {
        found.putIfAbsent(lit.$1, () => f.path);
      } else if (m.group(1) == 'Tx') {
        // Tx(cond ? 'a' : 'b'): the plain texts inside the argument.
        var depth = 1;
        var k = m.end;
        while (k < src.length && depth > 0) {
          final c = src[k];
          if ((c == "'" || c == '"') && src.substring(k >= 5 ? k - 5 : 0, k).contains('Key(')) {
            // key: Key('...') is not a text
            final l = _literals(src, k);
            k = l?.$2 ?? k + 1;
            continue;
          }
          if (c == "'" || c == '"') {
            final l = _literals(src, k);
            if (l != null) {
              final t = l.$1;
              if (RegExp(r'[A-Za-z]{2}').hasMatch(t) && !RegExp(r'^[a-z_.]+$').hasMatch(t)) found.putIfAbsent(t, () => f.path);
              k = l.$2;
              continue;
            }
            // an interpolated text: skip it
            var e = k + 1;
            while (e < src.length && src[e] != c) {
              if (src[e] == r'\') e++;
              e++;
            }
            k = e + 1;
            continue;
          }
          if (c == '(') depth++;
          if (c == ')') depth--;
          k++;
        }
      }
    }
  }
  return found;
}

/// Texts that are not translated on purpose (formats, codes).
const _notTranslated = {'user.login', 'd MMM, HH:mm'};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.current.value = AppLanguage.english;
    WalletStrings.somaliOverride = null;
  });
  tearDown(() => AppLanguage.current.value = AppLanguage.english);

  test('every text on a screen has its Somali (or, when it was written in Somali, its English)', () {
    final missing = <String>[];
    _usedTexts().forEach((text, file) {
      if (!RegExp(r'[A-Za-z]{2}').hasMatch(text) || _notTranslated.contains(text)) return;
      if (!somaliTexts.containsKey(text) && !englishTexts.containsKey(text)) missing.add('$text   ($file)');
    });
    expect(missing, isEmpty, reason: 'add these to lib/l10n/somali.dart:\n${missing.join('\n')}');
  });

  test('a translation keeps the same {0} {1} places as its text, and is never empty', () {
    String places(String s) => (RegExp(r'\{\d+\}').allMatches(s).map((m) => m.group(0)!).toList()..sort()).join();
    final problems = <String>[];
    for (final table in [somaliTexts, englishTexts]) {
      table.forEach((k, v) {
        if (v.trim().isEmpty) problems.add('empty: $k');
        if (places(k) != places(v)) problems.add('places differ: $k  ->  $v');
      });
    }
    expect(problems, isEmpty);
  });

  test('a text in neither table (a name, a number, a server message) is shown as it is', () {
    AppLanguage.current.value = AppLanguage.somali;
    expect(tr('Cali Xasan'), 'Cali Xasan');
    expect(tr('+252610000002'), '+252610000002');
    expect(trp('Hello {0}', ['Cali']), 'Hello Cali');
  });

  test('Somali and English, with values', () {
    expect(tr('Save'), 'Save');
    expect(trp('Welcome, {0}', ['Cali']), 'Welcome, Cali');
    AppLanguage.current.value = AppLanguage.somali;
    expect(tr('Save'), 'Keydi');
    expect(trp('Welcome, {0}', ['Cali']), 'Soo dhawoow, Cali');
    expect(trp('{0} deposits · {1} withdrawals', [3, 2]), '3 dhigasho · 2 bixin');
    // A text first written in Somali is English in English.
    expect(tr('Lacagaha Sugaya Xaqiijinta'), 'Lacagaha Sugaya Xaqiijinta');
    AppLanguage.current.value = AppLanguage.english;
    expect(tr('Lacagaha Sugaya Xaqiijinta'), 'Deposits Awaiting Confirmation');
  });

  test('the wallet screens follow the same setting', () {
    expect(WalletStrings.isSomali, isFalse);
    AppLanguage.current.value = AppLanguage.somali;
    expect(WalletStrings.isSomali, isTrue);
    expect(WalletStrings.addMoney, 'Lacag Ku Shub');
  });

  test('the choice is kept on the phone and read back', () async {
    await AppLanguage.set(AppLanguage.somali);
    expect((await SharedPreferences.getInstance()).getString('app_language'), 'so');
    AppLanguage.current.value = AppLanguage.english;
    await AppLanguage.load();
    expect(AppLanguage.current.value, AppLanguage.somali);
    await AppLanguage.set(AppLanguage.english);
    await AppLanguage.load();
    expect(AppLanguage.current.value, AppLanguage.english);
  });

  testWidgets('Tx shows the text in the chosen language and changes when it changes', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Tx('Cancel'))));
    expect(find.text('Cancel'), findsOneWidget);
    AppLanguage.current.value = AppLanguage.somali;
    // Tx is built again by the app's language scope; here by hand.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Tx('Cancel', key: ValueKey('again')))));
    expect(find.text('Jooji'), findsOneWidget);
  });
}
