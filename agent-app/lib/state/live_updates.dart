import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase Realtime feed of order and payment-confirmation changes. Row
/// level security limits it to what an agent may see. Screens listen to
/// [changes] and reload, so a new deposit, a matched SMS or a withdrawal
/// another agent finished shows up without pulling to refresh.
class LiveUpdates {
  LiveUpdates(this._client);

  final SupabaseClient Function() _client;
  final _controller = StreamController<String>.broadcast();
  RealtimeChannel? _channel;

  /// Emits the name of the table that changed.
  Stream<String> get changes => _controller.stream;

  void start() {
    if (_channel != null) return;
    final client = _client();
    var channel = client.channel('agent-live');
    for (final table in const ['orders', 'sms_transactions', 'winwin_transactions']) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _controller.add(table),
      );
    }
    _channel = channel..subscribe();
  }

  Future<void> stop() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client().removeChannel(channel);
  }
}

/// Reloads a screen when [LiveUpdates] reports a change (batched, so a burst
/// of changes causes one reload).
mixin LiveRefresh<T extends StatefulWidget> on State<T> {
  StreamSubscription<String>? _liveSub;
  Timer? _liveDebounce;

  void listenForLiveChanges(Stream<String> changes, VoidCallback reload) {
    _liveSub?.cancel();
    _liveSub = changes.listen((_) {
      _liveDebounce?.cancel();
      _liveDebounce = Timer(const Duration(milliseconds: 700), () {
        if (mounted) reload();
      });
    });
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    _liveDebounce?.cancel();
    super.dispose();
  }
}
