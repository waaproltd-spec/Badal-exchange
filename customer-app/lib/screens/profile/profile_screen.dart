import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/withdraw_limits.dart';
import '../../state/auth_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../theme/theme_mode.dart';
import '../../widgets/withdraw_limits_card.dart';
import '../auth/login_screen.dart';
import 'change_password_screen.dart';
import 'kyc_screen.dart';

const _green = Color(0xFF2EE59D);
const _amber = Color(0xFFE0A100);

/// Profile: who the customer is and their KYC status, withdrawal limits
/// (withdrawals only) with what was used and what is left, language,
/// appearance, KYC, password and log out -- compact, on one screen. The limits
/// come from the server, which enforces them; they reload whenever this tab
/// is opened.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  /// Bumped by the bottom bar when the Profile tab is opened.
  static final ValueNotifier<int> refresh = ValueNotifier<int>(0);

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  WithdrawLimits? _limits;

  @override
  void initState() {
    super.initState();
    ProfileScreen.refresh.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    ProfileScreen.refresh.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final limits = await context.read<CustomerApi>().getWithdrawLimits();
    if (mounted && limits != null) setState(() => _limits = limits);
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(AppStrings.logout),
        content: Text(AppStrings.logoutConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppStrings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(AppStrings.logout, style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    await context.read<AuthProvider>().logout();
    if (!context.mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _openKyc() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const KycScreen()));
    if (mounted) _load();
  }

  void _details() {
    final l = _limits;
    if (l == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.screenBackground,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: WithdrawLimitsCard(
            limits: l,
            onCompleteKyc: l.askKyc
                ? () {
                    Navigator.of(context).pop();
                    _openKyc();
                  }
                : null,
          ),
        ),
      ),
    );
  }

  String get _statusLabel {
    final l = _limits;
    if (l == null) return AppStrings.kycNotVerified;
    if (l.verified) return AppStrings.kycVerified;
    if (l.kycPending) return AppStrings.kycInReview;
    return AppStrings.kycNotVerified;
  }

  Color get _statusColor {
    final l = _limits;
    if (l != null && l.verified) return _green;
    if (l != null && l.kycPending) return _amber;
    return const Color(0xFFFF3B5C);
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final displayName = (user?.name.isNotEmpty ?? false) ? user!.name : '-';
    final initial = (user?.name.isNotEmpty ?? false) ? user!.name[0].toUpperCase() : '?';
    final l = _limits;

    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          // Fits one screen on phones; scrolls only on a very small one.
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  decoration: const BoxDecoration(gradient: AppColors.headerGradient),
                  padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 8, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppStrings.profile, style: AppTextStyles.appBarTitle.copyWith(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Container(
                        key: const Key('profile-header'),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white.withOpacity(0.16)),
                        ),
                        child: Row(children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(gradient: AppColors.brandGradient, shape: BoxShape.circle),
                            child: Center(child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800))),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(displayName,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                              Text(user?.phone ?? '-', style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13.5)),
                              const SizedBox(height: 4),
                              Container(
                                key: const Key('kyc-status'),
                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                decoration: BoxDecoration(color: _statusColor.withOpacity(0.18), borderRadius: BorderRadius.circular(20)),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.circle, size: 8, color: _statusColor),
                                  const SizedBox(width: 6),
                                  Flexible(child: Text(_statusLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _statusColor, fontWeight: FontWeight.w700, fontSize: 12.5))),
                                ]),
                              ),
                            ]),
                          ),
                        ]),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Panel(
                        key: const Key('profile-limits'),
                        child: Column(children: [
                          Row(children: [
                            const _IconDot(icon: Icons.account_balance_wallet_rounded, color: Color(0xFF7B2FF7)),
                            const SizedBox(width: 10),
                            Expanded(child: Text(AppStrings.withdrawLimitsTitle, style: _title)),
                            if (l != null)
                              InkWell(
                                key: const Key('limits-details'),
                                borderRadius: BorderRadius.circular(20),
                                onTap: _details,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(color: AppColors.primaryTint, borderRadius: BorderRadius.circular(20)),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    Flexible(child: Text(AppStrings.limitsDetails, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.primaryDark, fontSize: 12, fontWeight: FontWeight.w700))),
                                    Icon(Icons.chevron_right_rounded, size: 16, color: AppColors.primaryDark),
                                  ]),
                                ),
                              ),
                          ]),
                          const SizedBox(height: 8),
                          if (l == null)
                            Padding(padding: const EdgeInsets.all(14), child: Text('…', style: _title))
                          else ...[
                            _LimitRow(key: const Key('limit-daily'), title: AppStrings.dailyLimit, period: l.daily, base: const Color(0xFF7B2FF7)),
                            const SizedBox(height: 6),
                            _LimitRow(key: const Key('limit-monthly'), title: AppStrings.monthlyLimit, period: l.monthly, base: const Color(0xFFD02FF7)),
                          ],
                        ]),
                      ),
                      const SizedBox(height: 6),
                      _Panel(
                        child: Column(children: [
                        Row(children: [
                          const _IconDot(icon: Icons.language_rounded, color: Color(0xFF6A2BD9)),
                          const SizedBox(width: 10),
                          Flexible(flex: 0, child: Text(AppStrings.language, maxLines: 1, overflow: TextOverflow.ellipsis, style: _title)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ValueListenableBuilder<String>(
                              valueListenable: AppLanguage.current,
                              builder: (_, lang, __) => _Seg<String>(
                                key: const Key('language'),
                                value: lang,
                                onChanged: AppLanguage.set,
                                options: const [(AppLanguage.somali, null, AppStrings.somaliName), (AppLanguage.english, null, AppStrings.englishName)],
                              ),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 6),
                        Row(children: [
                          const _IconDot(icon: Icons.dark_mode_rounded, color: Color(0xFF6A2BD9)),
                          const SizedBox(width: 10),
                          Flexible(flex: 0, child: Text(AppStrings.appearance, maxLines: 1, overflow: TextOverflow.ellipsis, style: _title)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ValueListenableBuilder<ThemeMode>(
                              valueListenable: AppThemeMode.current,
                              builder: (_, mode, __) => _Seg<ThemeMode>(
                                key: const Key('theme-mode'),
                                value: mode,
                                onChanged: AppThemeMode.set,
                                options: [
                                  (ThemeMode.light, Icons.light_mode_rounded, AppStrings.themeLight),
                                  (ThemeMode.dark, Icons.dark_mode_rounded, AppStrings.themeDark),
                                  (ThemeMode.system, Icons.phone_android_rounded, AppStrings.themeSystem),
                                ],
                              ),
                            ),
                          ),
                        ]),
                        ]),
                      ),
                      const SizedBox(height: 6),
                      _NavPanel(
                        key: const Key('kyc-verification'),
                        icon: Icons.verified_user_rounded,
                        color: const Color(0xFFC21F4B),
                        title: AppLanguage.isSomali ? 'Xaqiijinta KYC' : 'KYC Verification',
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: _statusColor.withOpacity(0.16), borderRadius: BorderRadius.circular(20)),
                          child: Text(_statusLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _statusColor, fontWeight: FontWeight.w700, fontSize: 12)),
                        ),
                        onTap: _openKyc,
                      ),
                      const SizedBox(height: 6),
                      _NavPanel(
                        key: const Key('change-password'),
                        icon: Icons.lock_reset_rounded,
                        color: const Color(0xFF3B33C9),
                        title: AppStrings.changePassword,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('logout'),
                        onPressed: () => _confirmLogout(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.error,
                          side: const BorderSide(color: AppColors.error, width: 1.5),
                          minimumSize: const Size.fromHeight(40),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
                        ),
                        icon: const Icon(Icons.logout_rounded, size: 20),
                        label: Text(AppStrings.logout, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle get _title => AppTextStyles.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary);

class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.cardBorder, width: 1.1),
        ),
        child: child,
      );
}

class _IconDot extends StatelessWidget {
  const _IconDot({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, size: 17, color: Colors.white),
      );
}

class _NavPanel extends StatelessWidget {
  const _NavPanel({super.key, required this.icon, required this.color, required this.title, required this.onTap, this.trailing});
  final IconData icon;
  final Color color;
  final String title;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: _Panel(
          child: Row(children: [
            _IconDot(icon: icon, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: _title)),
            if (trailing != null) ...[Flexible(flex: 0, child: trailing!), const SizedBox(width: 6)],
            Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
          ]),
        ),
      );
}

/// A small pill selector (language, appearance).
class _Seg<T> extends StatelessWidget {
  const _Seg({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, IconData?, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.primaryTint,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(children: [
          for (final (v, icon, label) in options)
            Expanded(
              child: GestureDetector(
                key: Key('seg-$label'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(v),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  decoration: BoxDecoration(
                    gradient: v == value ? const LinearGradient(colors: [Color(0xFF7B2FF7), Color(0xFF5A22C9)]) : null,
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (icon != null) ...[Icon(icon, size: 15, color: v == value ? Colors.white : AppColors.textMuted), const SizedBox(width: 4)],
                      Text(label,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: v == value ? Colors.white : AppColors.textMuted)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// One limit: its size, the share used, what was used and what is left.
class _LimitRow extends StatelessWidget {
  const _LimitRow({super.key, required this.title, required this.period, required this.base});
  final String title;
  final LimitPeriod period;
  final Color base;

  @override
  Widget build(BuildContext context) {
    final empty = period.remainingValue <= 0;
    final near = period.fraction >= 0.8;
    final color = empty ? AppColors.error : near ? _amber : base;
    final percent = (period.fraction * 100).round();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(
        color: AppColors.primaryTint.withOpacity(0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text(title, style: _title.copyWith(fontSize: 14))),
          Text('\$${_short(period.limit)}', style: _title.copyWith(fontSize: 16, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: period.fraction,
                minHeight: 8,
                backgroundColor: AppColors.cardBorder.withOpacity(0.7),
                valueColor: AlwaysStoppedAnimation<Color>(empty ? AppColors.error : near ? _amber : _green),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('$percent%', style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 3),
        Row(children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${AppStrings.limitUsed}: ', style: TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                Text('\$${period.used}', style: _title.copyWith(fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${AppStrings.limitRemaining}: ', style: TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                Text('\$${period.remaining}',
                    style: TextStyle(color: empty ? AppColors.error : _green, fontSize: 13, fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ]),
      ]),
    );
  }

  /// 50.00 -> 50, 5000.00 -> 5000 (the limit is a whole amount unless set otherwise).
  static String _short(String v) => v.endsWith('.00') ? v.substring(0, v.length - 3) : v;
}
