import 'dart:io';
import 'dart:typed_data';

import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/services/success_sound.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CountingPlayer implements SoundPlayer {
  int plays = 0;

  @override
  Future<void> play() async => plays++;
}

final now = DateTime.utc(2026, 10, 28, 22, 0);

Order order(String id, String status, {String direction = 'deposit', DateTime? completedAt}) => Order(
      id: id,
      orderCode: 'EX${id.toUpperCase()}',
      direction: direction,
      method: 'evc_plus',
      status: status,
      statusMessage: '',
      amount: '10.00',
      fee: '0.00',
      netAmount: '10.00',
      createdAt: now.subtract(const Duration(minutes: 1)),
      completedAt: completedAt ?? (status == 'completed' ? now : null),
    );

void main() {
  late CountingPlayer player;
  late SuccessSound sound;

  SuccessSound fresh() => SuccessSound(player: player, now: () => now);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    player = CountingPlayer();
    sound = fresh();
  });

  test('a deposit seen pending, then completed: one cha-ching', () async {
    await sound.observe([order('a', 'pending')]);
    expect(player.plays, 0);
    await sound.observe([order('a', 'processing')]);
    expect(player.plays, 0);
    await sound.observe([order('a', 'completed')]);
    expect(player.plays, 1);
    // Reloads, live updates and other screens report it again: no repeat.
    await sound.observe([order('a', 'completed')]);
    await sound.observe([order('a', 'completed')]);
    expect(player.plays, 1);
  });

  test('a withdrawal completed: one cha-ching', () async {
    await sound.observe([order('w', 'pending', direction: 'withdraw')]);
    await sound.observe([order('w', 'completed', direction: 'withdraw')]);
    expect(player.plays, 1);
  });

  test('never for pending, processing, failed, cancelled or expired', () async {
    await sound.observe([
      order('p', 'pending'),
      order('r', 'processing', direction: 'withdraw'),
    ]);
    await sound.observe([
      order('p', 'failed'),
      order('r', 'cancelled', direction: 'withdraw'),
      order('x', 'expired'),
      order('f', 'failed', direction: 'withdraw'),
    ]);
    expect(player.plays, 0);
  });

  test('not after a restart: the device remembers it played', () async {
    await sound.observe([order('a', 'pending')]);
    await sound.observe([order('a', 'completed')]);
    expect(player.plays, 1);
    final again = fresh();
    await again.observe([order('a', 'completed')]);
    expect(player.plays, 1);
  });

  test('completed while the app was closed: plays when it is next seen', () async {
    await sound.observe([order('a', 'pending')]);
    // Hours later, after a restart.
    final later = SuccessSound(player: player, now: () => now.add(const Duration(hours: 5)));
    await later.observe([order('a', 'completed', completedAt: now.add(const Duration(hours: 1)))]);
    expect(player.plays, 1);
  });

  test("an old account's history does not play", () async {
    await sound.observe([
      order('old1', 'completed', completedAt: now.subtract(const Duration(days: 3))),
      order('old2', 'completed', direction: 'withdraw', completedAt: now.subtract(const Duration(hours: 1))),
    ]);
    expect(player.plays, 0);
  });

  test('completed just now, never seen pending (e.g. a fresh install): plays once', () async {
    await sound.observe([order('n', 'completed', completedAt: now.subtract(const Duration(minutes: 1)))]);
    await sound.observe([order('n', 'completed', completedAt: now.subtract(const Duration(minutes: 1)))]);
    expect(player.plays, 1);
  });

  test('several completed at once: one sound, and each only once', () async {
    await sound.observe([order('a', 'pending'), order('b', 'pending', direction: 'withdraw')]);
    await sound.observe([order('a', 'completed'), order('b', 'completed', direction: 'withdraw')]);
    expect(player.plays, 1);
    await sound.observe([order('a', 'completed'), order('b', 'completed', direction: 'withdraw')]);
    expect(player.plays, 1);
  });

  test('the same completion reported twice at the same moment: one sound', () async {
    await sound.observe([order('a', 'pending')]);
    await Future.wait([
      sound.observe([order('a', 'completed')]),
      sound.observe([order('a', 'completed')]),
      sound.observe([order('a', 'completed')]),
    ]);
    expect(player.plays, 1);
  });

  test('a player that fails never breaks the caller', () async {
    final s = SuccessSound(player: _FailingPlayer(), now: () => now);
    await s.observe([order('a', 'pending')]);
    await s.observe([order('a', 'completed')]);
  });

  test('the sound file is bundled: a short WAV, no longer than 2 seconds', () {
    final file = File('assets/sounds/cha_ching.wav');
    expect(file.existsSync(), isTrue);
    final bytes = file.readAsBytesSync();
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    final rate = bytes.buffer.asByteData().getUint32(24, Endian.little);
    final seconds = (bytes.length - 44) / (rate * 2);
    expect(seconds, lessThanOrEqualTo(2));
    expect(File('pubspec.yaml').readAsStringSync(), contains('assets/sounds/'));
  });
}

class _FailingPlayer implements SoundPlayer {
  @override
  Future<void> play() => Future.error(StateError('no audio'));
}
