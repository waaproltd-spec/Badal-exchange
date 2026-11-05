// The SMS that arrive while the app is closed: the headless engine takes what the Android receiver kept and
// runs it through the same pipeline as the open app -- Sahal's access code goes to the server (which enters it
// into the Sahal sign-in), payment SMS are uploaded, personal SMS are dropped, and nothing happens without a
// signed-in agent.
import 'package:badal_agent_app/api/agent_api.dart';
import 'package:badal_agent_app/api/api_client.dart';
import 'package:badal_agent_app/api/api_exception.dart';
import 'package:badal_agent_app/services/sms_log_store.dart';
import 'package:badal_agent_app/sms/sms_background.dart';
import 'package:badal_agent_app/sms/sms_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends ApiClient {
  _Client(this.signedIn);
  final bool signedIn;
  @override
  bool get hasSession => signedIn;
}

class _Api extends AgentApi {
  _Api({bool signedIn = true}) : super(client: _Client(signedIn));

  final codes = <Map<String, Object?>>[];
  final payments = <Map<String, Object?>>[];
  bool failNextPayment = false;

  @override
  Future<Map<String, dynamic>> submitSahalSmsCode({
    required String sender,
    required String body,
    required DateTime receivedAt,
    String? deviceId,
  }) async {
    codes.add({'sender': sender, 'deviceId': deviceId, 'body': body});
    return {'result': 'submitted'};
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
    if (failNextPayment) {
      failNextPayment = false;
      throw ApiException(statusCode: 400, code: 'VALIDATION_ERROR', message: 'bad');
    }
    payments.add({'provider': provider, 'amount': amount, 'ref': transactionRef, 'deviceId': deviceId});
    return {'matchStatus': 'unmatched'};
  }
}

Map<String, Object?> _sms(String sender, String body, {int? ago}) => {
      'sender': sender,
      'body': body,
      'timestampMillis': DateTime.now().subtract(Duration(seconds: ago ?? 0)).millisecondsSinceEpoch,
      'simSlot': 1,
    };

const _code = '-SAHAL SERVICES- Access code is 654321 DIGNIIN FADLAN QOFNA HALA WADAAGIN NUMBERADAN';
const _paid = '[SAHAL] Tix: 7543914546, Waxaad \$1 ka heshay  YASIIN MAXAMED AADAN (252610346060)\n Tar: , Haraagaagu waa \$225.35';

SmsBridge _bridge(_Api api) => SmsBridge(api: api, logStore: SmsLogStore.instance)..sahalRetryEvery = const Duration(milliseconds: 1);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Sahal\'s access code received while the app is closed reaches the server with this phone\'s id', () async {
    final api = _Api();
    final n = await SmsBackground.process([_sms('898', _code)], api: api, deviceId: 'phone-1', bridge: _bridge(api));
    expect(n, 1);
    expect(api.codes, hasLength(1));
    expect(api.codes.single['deviceId'], 'phone-1');
    expect(api.codes.single['body'], contains('654321'));
    expect(api.payments, isEmpty, reason: 'a code is never uploaded as a payment');
  });

  test('a Sahal payment SMS is uploaded; a personal SMS is dropped and sent nowhere', () async {
    final api = _Api();
    final n = await SmsBackground.process(
      [_sms('898', _paid), _sms('+252611111111', 'Nabad, ma joogtaa?')],
      api: api,
      deviceId: 'phone-1',
      bridge: _bridge(api),
    );
    expect(n, 2);
    expect(api.payments, hasLength(1));
    expect(api.payments.single['provider'], 'Sahal');
    expect(api.payments.single['ref'], '7543914546');
    expect(api.codes, isEmpty);
  });

  test('nothing is sent without a signed-in agent', () async {
    final api = _Api(signedIn: false);
    final n = await SmsBackground.process([_sms('898', _code), _sms('898', _paid)], api: api, deviceId: 'phone-1', bridge: _bridge(api));
    expect(n, 0);
    expect(api.codes, isEmpty);
    expect(api.payments, isEmpty);
  });

  test('one SMS that fails does not stop the next one', () async {
    final api = _Api()..failNextPayment = true;
    final n = await SmsBackground.process([_sms('898', _paid), _sms('898', _code)], api: api, deviceId: 'phone-1', bridge: _bridge(api));
    expect(n, 2, reason: 'both were handled (the first was refused, the second went through)');
    expect(api.codes, hasLength(1), reason: 'the code was still sent');
  });

  test('a malformed or empty entry from the receiver is skipped', () async {
    final api = _Api();
    final n = await SmsBackground.process([null, 'x', {'sender': '898'}, _sms('898', _code)], api: api, deviceId: 'phone-1', bridge: _bridge(api));
    expect(n, 1);
    expect(api.codes, hasLength(1));
  });

  test('a code older than 10 minutes is never sent (it is no good any more)', () async {
    final api = _Api();
    await SmsBackground.process([_sms('898', _code, ago: 11 * 60)], api: api, deviceId: 'phone-1', bridge: _bridge(api));
    expect(api.codes, isEmpty);
  });
}
