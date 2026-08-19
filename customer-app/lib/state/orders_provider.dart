import 'package:flutter/foundation.dart';

import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../models/order.dart';

class OrdersProvider extends ChangeNotifier {
  OrdersProvider({required this.customerApi});

  final CustomerApi customerApi;

  List<Order> _orders = const [];
  List<Order> get orders => _orders;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _orders = await customerApi.getOrders();
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load your orders. Check your connection and try again.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
