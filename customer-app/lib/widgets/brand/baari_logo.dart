import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/colors.dart';

/// The Badal Exchange logo mark: the white "b" on a rounded brand-purple
/// tile. Same artwork as the Android launcher icon.
class BaariLogoMark extends StatelessWidget {
  const BaariLogoMark({super.key, this.size = 48, this.onDark = false});

  final double size;

  /// On a dark purple header the tile gets a thin light outline so it does
  /// not dissolve into the header.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.22);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: onDark
            ? Border.all(color: Colors.white.withOpacity(0.35), width: math.max(1, size * 0.03))
            : null,
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryDeep.withOpacity(onDark ? 0.35 : 0.22),
            blurRadius: size * 0.3,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset('assets/brand/logo.png', width: size, height: size, fit: BoxFit.cover),
      ),
    );
  }
}

/// "BADAL EXCHANGE" wordmark with a short orange accent bar underneath.
class BaariWordmark extends StatelessWidget {
  const BaariWordmark({super.key, this.fontSize = 26, this.color});

  final double fontSize;
  /// Defaults to [AppColors.primaryDark].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'BADAL EXCHANGE',
          maxLines: 1,
          softWrap: false,
          style: GoogleFonts.plusJakartaSans(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: fontSize * 0.04,
            color: color ?? AppColors.primaryDark,
            height: 1.0,
          ),
        ),
        SizedBox(height: fontSize * 0.22),
        Container(
          width: fontSize * 1.1,
          height: math.max(3, fontSize * 0.13),
          decoration: BoxDecoration(
            color: AppColors.accentOrange,
            borderRadius: BorderRadius.circular(fontSize),
          ),
        ),
      ],
    );
  }
}

/// Logo mark + wordmark, side by side.
class BaariLogo extends StatelessWidget {
  const BaariLogo({super.key, this.markSize = 48, this.onDark = false});

  final double markSize;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BaariLogoMark(size: markSize, onDark: onDark),
        SizedBox(width: markSize * 0.28),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: BaariWordmark(
              fontSize: markSize * 0.52,
              color: onDark ? Colors.white : AppColors.primaryDark,
            ),
          ),
        ),
      ],
    );
  }
}
