import 'package:flutter_test/flutter_test.dart';
import 'package:badal_exchange_customer/models/order.dart';
import 'package:badal_exchange_customer/models/quote.dart';
import 'package:badal_exchange_customer/models/wallet.dart';

void main() {
  group('Wallet.fromJson', () {
    test('parses the real /customer/wallet response shape', () {
      final wallet = Wallet.fromJson(const {
        'availableBalance': '9.80',
        'pendingBalance': '0.00',
        'totalDeposit': '9.80',
        'totalWithdraw': '0.00',
      });

      expect(wallet.availableBalance, '9.80');
      expect(wallet.pendingBalance, '0.00');
      expect(wallet.totalDeposit, '9.80');
      expect(wallet.totalWithdraw, '0.00');
    });
  });

  group('Quote.fromJson', () {
    test('parses the real /customer/quotes response shape', () {
      final quote = Quote.fromJson(const {
        'quoteId': 'rate-id:fee-id:1000',
        'method': 'evc_plus',
        'direction': 'deposit',
        'amount': '10.00',
        'rate': 1,
        'fee': '0.20',
        'netAmount': '9.80',
        'walletDelta': '9.80',
      });

      expect(quote.method, 'evc_plus');
      expect(quote.direction, 'deposit');
      expect(quote.rate, 1);
      expect(quote.netAmount, '9.80');
    });

    test('accepts a fractional rate as a num', () {
      final quote = Quote.fromJson(const {
        'quoteId': 'q',
        'method': 'winwin',
        'direction': 'withdraw',
        'amount': '5.00',
        'rate': 0.98,
        'fee': '0.05',
        'netAmount': '4.90',
        'walletDelta': '5.05',
      });

      expect(quote.rate, 0.98);
    });
  });

  group('Order.fromJson', () {
    test('parses a completed deposit order', () {
      final order = Order.fromJson(const {
        'id': '0139b958-0b04-486d-a152-246792b369f6',
        'orderCode': 'EX5Q7YJC',
        'direction': 'deposit',
        'method': 'evc_plus',
        'status': 'completed',
        'statusMessage': 'Transaction completed successfully.',
        'phoneNumber': '252611111111',
        'winwinId': null,
        'depositCode': null,
        'amount': '10.00',
        'fee': '0.20',
        'netAmount': '9.80',
        'transactionRef': 'TXN1001',
        'failureReason': null,
        'createdAt': '2026-08-19T17:13:52.860Z',
        'completedAt': '2026-08-19T17:13:52.907Z',
      });

      expect(order.isDeposit, isTrue);
      expect(order.isEvc, isTrue);
      expect(order.status, 'completed');
      expect(order.completedAt, isNotNull);
    });

    test('parses a pending WinWin deposit order with a deposit code and no completedAt', () {
      final order = Order.fromJson(const {
        'id': 'abc',
        'orderCode': 'EXG6AUKX',
        'direction': 'deposit',
        'method': 'winwin',
        'status': 'pending',
        'statusMessage': 'Your transaction is being verified.',
        'phoneNumber': null,
        'winwinId': '7841228',
        'depositCode': 'X4H9',
        'amount': '8.00',
        'fee': '0.20',
        'netAmount': '7.80',
        'transactionRef': null,
        'failureReason': null,
        'createdAt': '2026-08-19T17:19:00.348Z',
        'completedAt': null,
      });

      expect(order.isDeposit, isTrue);
      expect(order.isEvc, isFalse);
      expect(order.depositCode, 'X4H9');
      expect(order.completedAt, isNull);
    });

    test('parses a failed withdrawal order with a failure reason', () {
      final order = Order.fromJson(const {
        'id': 'xyz',
        'orderCode': 'EX1234AB',
        'direction': 'withdraw',
        'method': 'evc_plus',
        'status': 'failed',
        'statusMessage': 'Transaction failed. Your balance was not charged.',
        'phoneNumber': '252611111111',
        'winwinId': null,
        'depositCode': null,
        'amount': '5.00',
        'fee': '0.05',
        'netAmount': '5.00',
        'transactionRef': null,
        'failureReason': 'Provider payout rejected',
        'createdAt': '2026-08-19T17:18:42.603Z',
        'completedAt': null,
      });

      expect(order.isDeposit, isFalse);
      expect(order.status, 'failed');
      expect(order.failureReason, 'Provider payout rejected');
    });
  });
}
