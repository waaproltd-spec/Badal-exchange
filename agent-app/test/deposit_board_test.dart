import 'package:badal_agent_app/models/deposit_board.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the board reads its summary and deposits', () {
    final b = DepositBoard.fromJson({
      'summary': {'pendingCount': 7, 'pendingCustomers': 6, 'pendingTotal': '125.00', 'expiredCount': 3, 'newCount': 4},
      'deposits': [
        {
          'id': 'o1', 'orderCode': 'EXDEP1', 'direction': 'deposit', 'method': 'evc_plus', 'status': 'pending',
          'customerId': 'c1', 'phoneNumber': '610346060', 'amount': '5.00', 'fee': '0.00', 'netAmount': '5.00',
          'createdAt': '2026-10-28T17:17:00Z', 'customerName': 'Axmed Cali', 'waitingSeconds': 7200,
        },
        {
          'id': 'o2', 'orderCode': 'EXDEP2', 'direction': 'deposit', 'method': 'telesom', 'status': 'expired',
          'customerId': 'c2', 'amount': '20.00', 'fee': '0.00', 'netAmount': '20.00',
          'createdAt': '2026-10-26T18:00:00Z', 'waitingSeconds': 1800,
        },
      ],
    });
    expect([b.pendingCount, b.pendingCustomers, b.pendingTotal, b.expiredCount, b.newCount], [7, 6, '125.00', 3, 4]);
    expect(b.deposits.first.customerName, 'Axmed Cali');
    expect(b.deposits.first.isPending, isTrue);
    expect(b.deposits.last.isPending, isFalse);
  });

  test('time waited in Somali', () {
    expect(waitedText(40), '40 ilbiriqsi');
    expect(waitedText(5 * 60), '5 daqiiqo');
    expect(waitedText(2 * 3600 + 5), '2 saac');
    expect(waitedText(3 * 86400), '3 maalin');
  });
}
