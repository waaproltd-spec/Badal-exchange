import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/order.dart';

/// Plays the cash register "cha-ching" (assets/sounds/cha_ching.wav, made
/// by tool/make_cha_ching.py) once when the backend reports a deposit or
/// withdrawal as completed. Only orders read from the server reach
/// [observe] (Orders, the live updates, the withdrawal's follow loop), so
/// pending, processing, failed and cancelled orders never play it.
///
/// Once per order: the ids it played for are kept on the device, so a
/// reload, another screen or a restart doesn't play it again. An order
/// plays only if this device saw it before it was completed, or it was
/// completed in the last [recent] -- not the history of an old account.
class SuccessSound {
  SuccessSound({SoundPlayer? player, Future<SharedPreferences> Function()? prefs, DateTime Function()? now})
      : _player = player ?? AudioSoundPlayer(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _now = now ?? DateTime.now;

  static SuccessSound instance = SuccessSound();

  static const recent = Duration(minutes: 5);
  static const _playedKey = 'success_sound.played';
  static const _waitingKey = 'success_sound.waiting';
  static const _keep = 200;

  final SoundPlayer _player;
  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _now;

  List<String>? _played;
  List<String>? _waiting;
  Future<void> _queue = Future.value();

  /// The orders as the server just reported them. Calls run one after
  /// another, so the same order arriving twice at once plays once.
  Future<void> observe(Iterable<Order> orders) {
    final list = orders.toList();
    return _queue = _queue.then((_) => _observe(list)).catchError((Object e) {
      debugPrint('success sound: $e');
    });
  }

  Future<void> _observe(List<Order> orders) async {
    final prefs = await _prefs();
    final played = _played ??= prefs.getStringList(_playedKey) ?? [];
    final waiting = _waiting ??= prefs.getStringList(_waitingKey) ?? [];
    var play = false;
    var changed = false;
    for (final o in orders) {
      if (o.direction != 'deposit' && o.direction != 'withdraw') continue;
      if (o.status == 'pending' || o.status == 'processing') {
        if (!waiting.contains(o.id)) {
          waiting.add(o.id);
          changed = true;
        }
        continue;
      }
      final wasWaiting = waiting.remove(o.id);
      changed |= wasWaiting;
      if (o.status != 'completed' || played.contains(o.id)) continue;
      final done = o.completedAt;
      if (wasWaiting || (done != null && _now().difference(done) < recent)) {
        played.add(o.id);
        changed = true;
        play = true;
      }
    }
    if (changed) {
      if (played.length > _keep) played.removeRange(0, played.length - _keep);
      if (waiting.length > _keep) waiting.removeRange(0, waiting.length - _keep);
      await prefs.setStringList(_playedKey, played);
      await prefs.setStringList(_waitingKey, waiting);
    }
    // Several at once (e.g. after being offline): one sound.
    if (play) await _player.play();
  }
}

/// Plays the sound; replaced in tests.
abstract class SoundPlayer {
  Future<void> play();
}

class AudioSoundPlayer implements SoundPlayer {
  /// Loud and clear but not at the phone's limit: the file peaks at
  /// -1 dBFS and the media volume the customer chose still applies.
  static const volume = 0.85;

  AudioPlayer? _audio;

  @override
  Future<void> play() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final audio = _audio ??= await _create();
      await audio.stop();
      await audio.play(AssetSource('sounds/cha_ching.wav'), volume: volume);
    } catch (e) {
      // No sound (no audio device, a test): the transaction is unaffected.
      debugPrint('cha-ching not played: $e');
    }
  }

  static Future<AudioPlayer> _create() async {
    final audio = AudioPlayer();
    await audio.setReleaseMode(ReleaseMode.stop);
    // Music the customer is playing dips for a moment instead of stopping.
    await audio.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        contentType: AndroidContentType.sonification,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
    ));
    return audio;
  }
}
