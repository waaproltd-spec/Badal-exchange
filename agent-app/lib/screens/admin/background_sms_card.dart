import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/tr.dart';
import '../../sms/sms_background.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';

/// Can this phone read Sahal's access code while the app is closed? Shows the two things Android decides
/// (the SMS permission and "no battery restriction") and the short trail of what the last background read did,
/// so a failure can be seen on the phone itself.
class BackgroundSmsCard extends StatefulWidget {
  const BackgroundSmsCard({super.key, this.smsGranted, this.batteryFree, this.askBattery, this.trail});

  final Future<bool> Function()? smsGranted;
  final Future<bool> Function()? batteryFree;
  final Future<bool> Function()? askBattery;
  final Future<List<String>> Function()? trail;

  @override
  State<BackgroundSmsCard> createState() => _BackgroundSmsCardState();
}

class _BackgroundSmsCardState extends State<BackgroundSmsCard> with WidgetsBindingObserver {
  bool? _sms;
  bool? _battery;
  List<String> _lines = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final sms = await (widget.smsGranted ?? () async => (await Permission.sms.status).isGranted)();
      final battery = await (widget.batteryFree ?? () async => (await Permission.ignoreBatteryOptimizations.status).isGranted)();
      final lines = await (widget.trail ?? BackgroundSmsLog.lines)();
      if (!mounted) return;
      setState(() {
        _sms = sms;
        _battery = battery;
        _lines = lines;
      });
    } catch (_) {}
  }

  Future<void> _ask() async {
    try {
      await (widget.askBattery ?? () async => (await Permission.ignoreBatteryOptimizations.request()).isGranted)();
    } catch (_) {}
    await _load();
  }

  Widget _row(IconData ok, IconData bad, bool? value, String label, {Widget? action}) {
    final good = value == true;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Icon(value == null ? Icons.hourglass_empty_rounded : (good ? ok : bad),
            size: 20, color: value == null ? null : (good ? AppColors.statusCompleted : AppColors.statusFailed)),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        if (!good && value != null && action != null) action,
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _lines.length > 5 ? _lines.sublist(_lines.length - 5) : _lines;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GroupLabel(tr('Reading the code while the app is closed')),
      Card(
        key: const Key('background-sms-card'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row(Icons.check_circle_rounded, Icons.error_rounded, _sms, tr('SMS permission allowed')),
            _row(Icons.check_circle_rounded, Icons.error_rounded, _battery, tr('No battery restriction for this app'),
                action: TextButton(
                  key: const Key('background-sms-allow'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
                  onPressed: _ask,
                  child: Text(tr('Allow')),
                )),
            const SizedBox(height: 6),
            Text(tr('Last background reads'), style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            if (shown.isEmpty)
              Text(tr('Nothing yet: it shows here when an SMS arrives while the app is closed.'), key: const Key('background-sms-empty'))
            else
              for (var i = 0; i < shown.length; i++) Text(shown[i], key: Key('background-sms-line-$i'), style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    ]);
  }
}
