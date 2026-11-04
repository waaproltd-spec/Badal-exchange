import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/app_lock.dart';
import '../../theme/colors.dart';
import 'verification_settings_panel.dart';

/// Profile > Verification lock: the settings page (see [VerificationSettingsPanel]).
class VerificationSettingsScreen extends StatelessWidget {
  const VerificationSettingsScreen({super.key, this.lock});

  /// Tests pass their own; the app uses [AppLock.instance].
  final AppLock? lock;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(
        title: Text(AppStrings.verificationLock),
        backgroundColor: AppColors.purpleDark,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          VerificationSettingsPanel(lock: lock),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.shield_outlined, size: 18, color: AppColors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(AppStrings.fingerprintPrivacy,
                  key: const Key('fingerprint-privacy'), style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
            ),
          ]),
        ],
      ),
    );
  }
}
