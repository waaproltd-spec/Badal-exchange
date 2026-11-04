import 'package:flutter/material.dart';

import 'language.dart';
import 'somali.dart';

/// Translates a screen text: the English text is the key, and in Somali the
/// matching entry of [somaliTexts] is shown. A text that is not in the table
/// (a name, a number, a message from the server) is shown as it is.
String tr(String english) {
  if (!AppLanguage.isSomali) return english;
  return somaliTexts[english] ?? english;
}

/// [tr] for a text with values in it: `trp('Welcome, {0}', [name])`. The
/// {0}, {1} ... stand where the values go, in both languages.
String trp(String english, List<Object?> values) {
  var text = tr(english);
  for (var i = 0; i < values.length; i++) {
    text = text.replaceAll('{$i}', '${values[i]}');
  }
  return text;
}

/// A [Text] that translates itself when it is built, so it can stay `const`.
/// Takes the same arguments as [Text] that the app uses.
class Tx extends StatelessWidget {
  const Tx(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;

  @override
  Widget build(BuildContext context) =>
      Text(tr(text), style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow, softWrap: softWrap);
}
