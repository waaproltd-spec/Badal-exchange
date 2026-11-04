import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_exception.dart';
import '../utils/network_error.dart';
import '../api/customer_api.dart';
import '../models/order.dart';
import '../l10n/strings.dart';
import '../services/success_sound.dart';

class OrdersProvider extends ChangeNotifier {
  OrdersProvider({required this.customerApi}) {
    // Realtime: reload in place when the backend reports a change.
    _liveSub = customerApi.liveChanges.listen((table) {
      if (_loaded && (table == 'orders' || table == 'wallets')) load(silent: true);
    });
  }

  StreamSubscription<String>? _liveSub;
  bool _loaded = false;

  /// While any order is not final the server is still confirming it: ask
  /// again every few seconds (the live update usually arrives first).
  static const recheckEvery = Duration(seconds: 5);
  Timer? _recheck;
  bool _disposed = false;

  final CustomerApi customerApi;

  List<Order> _orders = const [];
  List<Order> get orders => _orders;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  /// The last load failed because of the internet connection (not the server): the screens show the
  /// friendly internet message, and the load is repeated by itself until the connection is back.
  bool get networkProblem => _networkProblem;
  bool _networkProblem = false;
  Timer? _networkRetry;
  static const networkRetryEvery = Duration(seconds: 6);

  void _afterFailure(Object e) {
    _networkProblem = isNetworkError(e);
    _networkRetry?.cancel();
    _networkRetry = _networkProblem ? Timer(networkRetryEvery, () => load(silent: true)) : null;
  }

  Future<void> load({bool silent = false}) async {
    _loaded = true;
    if (!silent) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    try {
      _orders = await customerApi.getOrders();
      // A deposit or withdrawal the server now reports completed: cha-ching.
      SuccessSound.instance.observe(_orders);
      _error = null;
      _networkProblem = false;
      _networkRetry?.cancel();
    } on ApiException catch (e) {
      _afterFailure(e);
      if (!silent) _error = e.message;
    } catch (e) {
      _afterFailure(e);
      if (silent) return;
      _error = _networkProblem ? AppStrings.networkBody : AppStrings.couldNotLoadOrders;
    } finally {
      if (!_disposed) {
        _loading = false;
        notifyListeners();
        _recheck?.cancel();
        _recheck = _orders.any((o) => !o.isFinal) ? Timer(recheckEvery, () => load(silent: true)) : null;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _recheck?.cancel();
    _networkRetry?.cancel();
    _liveSub?.cancel();
    super.dispose();
  }
}
