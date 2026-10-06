import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/colors.dart';

/// The BAARI logo mark: a purple gradient squircle carrying a geometric
/// white "B" monogram, with a gold five-pointed star (a nod to the Somali
/// star) at its top right. Mirrors the Android launcher icon.
class BaariLogoMark extends StatelessWidget {
  const BaariLogoMark({super.key, this.size = 48, this.onDark = false});

  final double size;

  /// On a dark purple header the tile gets a thin light outline so it does
  /// not dissolve into the header.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(size * 0.3),
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
      child: CustomPaint(painter: _BaariMarkPainter()),
    );
  }
}

class _BaariMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final left = s * 0.28;
    final top = s * 0.26;
    final mid = s * 0.49;
    final bottom = s * 0.74;
    final upperR = (mid - top) / 2;
    final lowerR = (bottom - mid) / 2;
    final upperX = s * 0.58 - upperR;
    final lowerX = s * 0.66 - lowerR;

    // Geometric "B": stem, a smaller upper bowl and a wider lower bowl.
    final b = Path()
      ..moveTo(left, mid)
      ..lineTo(upperX, mid)
      ..arcToPoint(Offset(upperX, top), radius: Radius.circular(upperR), clockwise: false)
      ..lineTo(left, top)
      ..lineTo(left, bottom)
      ..lineTo(lowerX, bottom)
      ..arcToPoint(Offset(lowerX, mid), radius: Radius.circular(lowerR), clockwise: false)
      ..lineTo(left, mid);
    canvas.drawPath(b, stroke);

    // Gold star.
    final star = Paint()..color = AppColors.gold;
    canvas.drawPath(_star(Offset(s * 0.76, s * 0.27), s * 0.1), star);
  }

  Path _star(Offset c, double r) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? r : r * 0.45;
      final angle = -math.pi / 2 + i * math.pi / 5;
      final p = Offset(c.dx + radius * math.cos(angle), c.dy + radius * math.sin(angle));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// "BAARI" wordmark with a short orange accent bar underneath.
class BaariWordmark extends StatelessWidget {
  const BaariWordmark({super.key, this.fontSize = 26, this.color = AppColors.primaryDark});

  final double fontSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'BAARI',
          style: GoogleFonts.plusJakartaSans(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: fontSize * 0.12,
            color: color,
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
        BaariWordmark(
          fontSize: markSize * 0.52,
          color: onDark ? Colors.white : AppColors.primaryDark,
        ),
      ],
    );
  }
}
