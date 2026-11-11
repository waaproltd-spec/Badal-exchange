import 'package:badal_agent_app/models/payout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('EVC *736: the code fills {CODE}; the PIN is not part of the dialed string', () {
    final start = PayoutDialStart.fromJson({
      'id': 'a1',
      'step1UssdString': '*736*610346060*01*{CODE}#',
      'simSlot': 1,
      'isNew': true,
      'pin': '1111',
      'code': '2222',
    });
    expect(start.dialString, '*736*610346060*01*2222#');
    expect(start.pin, '1111');
  });

  test('eDahab: no code, dialed as the server sent it', () {
    final start = PayoutDialStart.fromJson({'id': 'a2', 'step1UssdString': '*110*621234567*5#', 'isNew': true, 'pin': '1111'});
    expect(start.dialString, '*110*621234567*5#');
  });
}
