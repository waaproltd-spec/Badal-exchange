import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';

/// "Internet-kaagu ma fiicna": shown where something could not be loaded because of the internet
/// connection (never the technical error), with a retry button. Nothing here says the list is empty.
class NetworkProblemView extends StatelessWidget {
  const NetworkProblemView({super.key, required this.onRetry, this.compact = false});

  final VoidCallback onRetry;

  /// Inside a card on Home (less padding).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 76,
          height: 64,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(Icons.wifi_rounded, size: 56, color: AppColors.primary),
              Positioned(
                right: 4,
                bottom: 0,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(color: AppColors.error, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(AppStrings.networkTitle,
            key: const Key('network-title'),
            textAlign: TextAlign.center,
            style: AppTextStyles.title.copyWith(fontSize: 20)),
        const SizedBox(height: 6),
        Text(AppStrings.networkBody, key: const Key('network-body'), textAlign: TextAlign.center, style: AppTextStyles.muted),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            key: const Key('network-retry'),
            onPressed: onRetry,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.textOnPrimary,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            ),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(AppStrings.networkRetry, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ),
      ],
    );
    return Container(
      key: const Key('network-problem'),
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: compact ? 20 : 28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.cardBorder, width: 1.2),
      ),
      child: content,
    );
  }
}
