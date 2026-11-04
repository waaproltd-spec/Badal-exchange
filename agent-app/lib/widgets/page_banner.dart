import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../theme/app_theme.dart';

/// The purple header of a tab: a soft gradient with a few round shapes, rounded at the bottom, in the
/// app's own header colours. [icon] (or [leading]) sits in a tile at the left, then [title] and
/// [subtitle]; [art] is the faint picture at the right. With [topInset] it also covers the status bar
/// (a tab with no app bar of its own).
class PageBanner extends StatelessWidget {
  const PageBanner({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.art,
    this.topInset = true,
    this.titleSize = 26,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final IconData? art;
  final bool topInset;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    final top = topInset ? MediaQuery.paddingOf(context).top : 0.0;
    return Container(
      key: const Key('page-banner'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.header, Color.lerp(AppColors.header, AppColors.primary, 0.35)!],
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: Stack(
        children: [
          Positioned(right: -40, top: -30, child: _Circle(170, 0.07)),
          Positioned(right: 40, bottom: -70, child: _Circle(150, 0.06)),
          if (art != null) Positioned(right: 18, bottom: 14, child: Icon(art, size: 64, color: AppColors.onHeader.withOpacity(0.22))),
          Padding(
            padding: EdgeInsets.fromLTRB(20, top + 16, 20, 20),
            child: Row(
              children: [
                if (leading != null || icon != null) ...[
                  leading ??
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppColors.onHeader.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(icon, color: AppColors.onHeader, size: 30),
                      ),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Tx(title,
                          style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w800, color: AppColors.onHeader, height: 1.1)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Tx(subtitle!, style: TextStyle(fontSize: 15, color: AppColors.onHeader.withOpacity(0.85))),
                      ],
                    ],
                  ),
                ),
                if (art != null) const SizedBox(width: 64),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle(this.size, this.opacity);

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.onHeader.withOpacity(opacity)),
      );
}
