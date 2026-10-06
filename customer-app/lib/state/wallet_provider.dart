import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../models/wallet.dart';

class WalletProvider extends ChangeNotifier {
  WalletProvider({required this.customerApi}) {
    // Realtime: reload in place when the backend reports a change.
    _liveSub = customerApi.liveChanges.listen((table) {
      if (_loaded && (table == 'orders' || table == 'wallets')) load(silent: true);
    });
  }

  StreamSubscription<String>? _liveSub;
  bool _loaded = false;

  final CustomerApi customerApi;

  Wallet? _wallet;
  Wallet? get wallet => _wallet;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  Future<void> load({bool silent = false}) async {
    _loaded = true;
    if (!silent) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    try {
      _wallet = await customerApi.getWallet();
      _error = null;
    } on ApiException catch (e) {
      if (!silent) _error = e.message;
    } catch (_) {
      if (silent) return;
      _error = 'Could not load your wallet. Check your connection and try again.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    super.dispose();
  }
}
