import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/services/sms_log_store.dart';
import 'package:badal_agent_app/sms/sahal_sms.dart';
import 'package:badal_agent_app/sms/sms_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends AgentApi {
  _Api(this.answers);

  /// What the server says to each try, in order; the last one repeats.
  final List<Object> answers;
  final tries = <Map<String, Object?>>[];
  int paymentUploads = 0;

  @override
  Future<Map<String, dynamic>> submitSahalSmsCode({
    required String sender,
    required String body,
    required DateTime receivedAt,
    String? deviceId,
  }) async {
    tries.add({'sender': sender, 'body': body, 'deviceId': deviceId});
    final a = answers[tries.length > answers.length ? answers.length - 1 : tries.length - 1];
    if (a is Exception) throw a;
    return {'result': a};
  }

  @override
  Future<Map<String, dynamic>> ingestPaymentSms({
    required String sender,
    required String body,
    required DateTime receivedAt,
    String? provider,
    String? amount,
    String? phone,
    String? transactionRef,
    int? simSlot,
    String? deviceId,
  }) async {
    paymentUploads++;
    return {'matchStatus': 'unmatched'};
  }
}

PendingSms _sms(String body, {String sender = '898', Duration age = Duration.zero}) =>
    PendingSms(sender: sender, body: body, receivedAt: DateTime.now().subtract(age), deviceId: 'dev-1');

const _code = '-SAHAL SERVICES- Access code is 654321 DIGNIIN FADLAN QOFNA HALA WADAAGIN NUMBERADAN';

SmsBridge _bridge(_Api api) => SmsBridge(api: api, logStore: SmsLogStore.instance)
  ..sahalRetryEvery = const Duration(milliseconds: 1);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SahalSms.looksLikeCode', () {
    test('Sahal\'s access-code SMS', () {
      expect(SahalSms.looksLikeCode('898', _code), isTrue, reason: 'as Sahal sends it');
      expect(SahalSms.looksLikeCode('SAHAL', _code), isTrue);
      expect(SahalSms.looksLikeCode('+252900000001', 'Your access code is 8712. Do not share it.'), isTrue);
      expect(SahalSms.looksLikeCode('sahal', 'Verification 123456'), isTrue);
    });

    test('anything else is not', () {
      expect(SahalSms.looksLikeCode('Mom', 'See you at 5, call me on 0612345678'), isFalse);
      expect(SahalSms.looksLikeCode('SAHAL', 'Welcome to Sahal Services'), isFalse, reason: 'no number');
      expect(SahalSms.looksLikeCode('192', 'Your bank code is 1234'), isFalse, reason: 'not Sahal');
      expect(SahalSms.looksLikeCode('EVCPLUS', '[-EVCPLUS-] waxaad \$5 ka heshay 252611234567 haraagaagu waa \$9'), isFalse);
    });
  });

  group('SmsBridge and Sahal\'s code', () {
    test('sent once, and the log never holds the code', () async {
      final api = _Api(['submitted']);
      final bridge = _bridge(api);
      await bridge.handleSms(_sms(_code));
      expect(api.tries, hasLength(1));
      expect(api.paymentUploads, 0, reason: 'not uploaded as a payment SMS');
      final log = await SmsLogStore.instance.loadAll();
      expect(log, hasLength(1));
      expect(log.single.provider, 'Sahal');
      expect(log.single.errorMessage, 'Access code sent to Sahal automatically');
      expect(log.map((e) => '${e.provider}${e.sender}${e.amount}${e.transactionRef}${e.errorMessage}').join().contains('654321'), isFalse);
    });

    test('Sahal not waiting yet (the SMS beat the server): tried again, then entered', () async {
      final api = _Api(['not_waiting', 'not_waiting', 'submitted']);
      await _bridge(api).handleSms(_sms(_code));
      expect(api.tries, hasLength(3));
      expect((await SmsLogStore.instance.loadAll()).single.errorMessage, 'Access code sent to Sahal automatically');
    });

    test('network down: tried again, and a clear message if it never works', () async {
      final api = _Api([ApiException(statusCode: 0, code: 'NETWORK', message: 'offline')]);
      final bridge = _bridge(api)..sahalAttempts = 3;
      await bridge.handleSms(_sms(_code));
      expect(api.tries, hasLength(3));
      final log = await SmsLogStore.instance.loadAll();
      expect(log.single.errorMessage, contains('type it in Sahal Sign-in'));
      expect(log.map((e) => '${e.provider}${e.sender}${e.amount}${e.transactionRef}${e.errorMessage}').join().contains('654321'), isFalse);
    });

    test('a final answer is not repeated and says nothing for ignored / expired / off', () async {
      for (final r in ['ignored', 'expired', 'off']) {
        SharedPreferences.setMockInitialValues({});
        final api = _Api([r]);
        await _bridge(api).handleSms(_sms(_code));
        expect(api.tries, hasLength(1), reason: r);
        expect(await SmsLogStore.instance.loadAll(), isEmpty, reason: r);
      }
    });

    test('an old SMS (read from the inbox after a restart) is never sent', () async {
      final api = _Api(['submitted']);
      await _bridge(api).handleSms(_sms(_code, age: const Duration(minutes: 11)));
      expect(api.tries, isEmpty);
    });

    test('other SMS are not sent to Sahal\'s endpoint', () async {
      final api = _Api(['submitted']);
      await _bridge(api).handleSms(_sms('Dinner at 7?', sender: 'Mom'));
      expect(api.tries, isEmpty);
    });
  });
}
