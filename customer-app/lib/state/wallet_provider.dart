import 'package:flutter/foundation.dart';

import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../models/wallet.dart';

class WalletProvider extends ChangeNotifier {
  WalletProvider({required this.customerApi});

  final CustomerApi customerApi;

  Wallet? _wallet;
  Wallet? get wallet => _wallet;

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _wallet = await customerApi.getWallet();
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load your wallet. Check your connection and try again.';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
