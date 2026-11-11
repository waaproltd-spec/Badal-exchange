import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// The Somali voice instruction of the Complete Deposit screen (mobile money:
/// EVC Plus, eDahab, Zaad, Golis). It plays once when the screen opens and is
/// stopped when the customer leaves. It only speaks: it never confirms or
/// changes a deposit.
abstract class DepositVoice {
  Future<void> play();
  Future<void> stop();
  Future<void> dispose();
}

class AudioDepositVoice implements DepositVoice {
  static const asset = 'sounds/deposit_instruction.mp3';
  static const volume = 1.0;

  AudioPlayer? _audio;
  bool _stopped = false;

  @override
  Future<void> play() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final audio = _audio ??= AudioPlayer();
      await audio.setReleaseMode(ReleaseMode.stop);
      await audio.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.speech,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ));
      if (_stopped) return; // the customer already left
      await audio.play(AssetSource(asset), volume: volume);
      if (_stopped) await audio.stop();
    } catch (e) {
      debugPrint('deposit voice not played: $e'); // no sound: the deposit is unaffected
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    try {
      await _audio?.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _stopped = true;
    try {
      await _audio?.dispose();
    } catch (_) {}
    _audio = null;
  }
}
