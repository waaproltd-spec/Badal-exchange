import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// EVC Plus = green rounded-square icon with a checkmark (Hormuud-style
/// green). WinWin = green circular icon.
class MethodIcon extends StatelessWidget {
  const MethodIcon({super.key, required this.method, this.size = 48});

  /// 'evc_plus' | 'winwin'
  final String method;
  final double size;

  bool get _isEvc => method == 'evc_plus';

  @override
  Widget build(BuildContext context) {
    final background = _isEvc ? AppColors.evcGreen : AppColors.winwinGreen;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        shape: _isEvc ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: _isEvc ? BorderRadius.circular(size * 0.28) : null,
      ),
      child: Icon(
        _isEvc ? Icons.check_rounded : Icons.sync_alt_rounded,
        color: Colors.white,
        size: size * 0.55,
      ),
    );
  }
}
