import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../models/withdraw_limits.dart';
import '../../models/withdrawal_access.dart';
import '../../theme/colors.dart';
import '../../utils/payment_errors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/flow_header.dart';
import '../../widgets/own_phone_box.dart';
import '../../widgets/payment_method_sheet.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/withdraw_limits_card.dart';
import '../profile/kyc_screen.dart';
import 'withdraw_confirm_screen.dart';

/// Collects the amount (plus the account ID for betting platforms), then
/// fetches a quote (which also enforces min/max withdrawal limits
/// server-side) before moving to confirmation. Mobile money is always paid
/// out to the customer's registered login number (the backend enforces
/// it), so there is no phone field.
class WithdrawDetailsScreen extends StatefulWidget {
  const WithdrawDetailsScreen({super.key, required this.method, this.ownPhone, this.option, this.availableBalance});

  /// Payment method id (see payment_method.dart).
  final String method;

  /// The method as the backend offers it (withdrawal limits), when known.
  final PaymentMethodOption? option;

  /// The wallet's available balance, shown at the top when known.
  final String? availableBalance;

  /// The customer's registered login phone: where mobile money is paid out.
  final String? ownPhone;

  @override
  State<WithdrawDetailsScreen> createState() => _WithdrawDetailsScreenState();
}

class _WithdrawDetailsScreenState extends State<WithdrawDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _amountController = TextEditingController();
  bool _submitting = false;
  String? _error;

  /// Null until known (and when it cannot be read: the server decides anyway).
  WithdrawalAccess? _access;

  /// KYC status and daily / monthly limits. Null until known or when it
  /// cannot be read: the server enforces them on every withdrawal anyway.
  WithdrawLimits? _limits;

  bool get _blocked => _access != null && !_access!.allowed;

  @override
  void initState() {
    super.initState();
    _checkAccess();
    _loadLimits();
  }

  Future<void> _loadLimits() async {
    final limits = await context.read<CustomerApi>().getWithdrawLimits();
    if (mounted) setState(() => _limits = limits);
  }

  Future<void> _openKyc() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const KycScreen()));
    if (mounted) _loadLimits();
  }

  /// Why [amount] cannot be withdrawn now, or null (the server decides anyway).
  String? _limitProblem(double amount) {
    final l = _limits;
    if (l == null || !l.enabled) return null;
    if (l.reached || !l.canWithdraw) {
      return l.warning == 'monthly_reached' ? AppStrings.limitMonthlyReached : AppStrings.limitDailyReached;
    }
    if (amount > l.availableValue + 0.0001) return AppStrings.limitExceeds(l.availableNow);
    return null;
  }

  /// Before the first withdrawal an admin approves the account.
  Future<void> _checkAccess() async {
    final access = await context.read<CustomerApi>().getWithdrawalAccess();
    if (mounted) setState(() => _access = access);
  }

  Uri? get _whatsappLink => _access?.whatsappLink(
        platform: _info.isPlatform ? _info.label : null,
        platformAccountId: _info.isPlatform ? _identifierController.text.trim() : null,
      );

  Future<void> _openWhatsapp() async {
    final link = _whatsappLink;
    if (link == null) return;
    try {
      await launchUrl(link, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No WhatsApp: the number is on the sheet to copy.
    }
  }

  /// First withdrawal, account not approved: WhatsApp opens with the
  /// message for the admin, and the sheet says why. Nothing is created and
  /// nothing is taken (the server refuses it anyway).
  Future<void> _askForApproval() async {
    _openWhatsapp();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ApprovalSheet(access: _access!, onWhatsapp: _openWhatsapp),
    );
  }

  PaymentMethodInfo get _info => methodInfo(widget.method);

  /// Last 9 digits of the registered number.
  String? get _ownLocal {
    final digits = (widget.ownPhone ?? '').replaceAll(RegExp(r'\D'), '');
    return digits.length >= 9 ? digits.substring(digits.length - 9) : null;
  }

  @override
  void dispose() {
    _identifierController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  /// The whole available balance, or the method's maximum when that is less.
  /// Nothing is sent: it only fills the amount, which is checked as always.
  void _fillAll() {
    final balance = double.tryParse(widget.availableBalance ?? '');
    if (balance == null || balance <= 0) return;
    var all = balance;
    final room = _limits;
    if (room != null && room.enabled && room.availableValue < all) all = room.availableValue;
    final cap = double.tryParse(widget.option?.maxWithdraw ?? '');
    if (cap != null && cap < all) all = cap;
    // Down to the cent, never above the balance.
    final text = ((all * 100).floor() / 100).toStringAsFixed(2);
    _amountController.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    if (_error != null) setState(() => _error = null);
  }

  Future<void> _continue() async {
    if (!_formKey.currentState!.validate()) return;
    if (_blocked) {
      await _askForApproval();
      return;
    }
    if (!_info.isPlatform && _ownLocal == null) {
      setState(() => _error = AppStrings.noRegisteredNumber);
      return;
    }
    final problem = _limitProblem(double.tryParse(_amountController.text.trim()) ?? 0);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final quote = await context.read<CustomerApi>().createQuote(
            direction: 'withdraw',
            method: widget.method,
            amount: _amountController.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WithdrawConfirmScreen(
            quote: quote,
            phoneNumber: _info.isPlatform ? null : '252$_ownLocal',
            accountId: _info.isPlatform ? _identifierController.text.trim() : null,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (e.code == 'WITHDRAWAL_VERIFICATION_REQUIRED') {
        await _checkAccess();
        if (mounted && _blocked) await _askForApproval();
        return;
      }
      if ((e.code.startsWith('WITHDRAWAL_') && e.code.endsWith('_LIMIT')) || e.code == 'WITHDRAWAL_KYC_REQUIRED') _loadLimits();
      setState(() => _error = PaymentErrors.handle(context.read<CustomerApi>(), e,
          isDeposit: false, method: widget.method, amount: _amountController.text.trim()));
    } catch (e) {
      setState(() => _error = PaymentErrors.handle(context.read<CustomerApi>(), e,
          isDeposit: false, method: widget.method, amount: _amountController.text.trim()));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _change() async {
    final option = await showPaymentMethodSheet(context, PaymentDirection.withdraw, ownPhone: widget.ownPhone);
    if (option == null || !mounted || option.info.id == widget.method) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => WithdrawDetailsScreen(
        method: option.info.id,
        option: option,
        ownPhone: widget.ownPhone,
        availableBalance: widget.availableBalance,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final min = widget.option?.minWithdraw;
    final max = widget.option?.maxWithdraw;
    final account = AppTextField(
      label: _info.identifierLabel,
      controller: _identifierController,
      keyboardType: TextInputType.text,
      hint: _info.identifierHint,
      textInputAction: TextInputAction.next,
      validator: (v) => (v == null || v.trim().isEmpty) ? AppStrings.enterAccountId : null,
    );
    final amount = AppTextField(
      label: AppStrings.amount,
      controller: _amountController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      hint: '0.00',
      textInputAction: TextInputAction.done,
      validator: (v) {
        final n = double.tryParse((v ?? '').trim());
        if (n == null || n <= 0) return AppStrings.enterValidAmount;
        return null;
      },
    );
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Row(
                children: [
                  RoundIconButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 14),
                  Expanded(child: Text(AppStrings.completeWithdrawal, style: AppTextStyles.title)),
                ],
              ),
              const SizedBox(height: 20),
              if (widget.availableBalance != null) ...[
                Container(
                  key: const Key('withdraw-available'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.cardBorder, width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppStrings.availableBalance.toUpperCase(), style: AppTextStyles.label),
                      const SizedBox(height: 4),
                      Text(Formatters.money(widget.availableBalance!),
                          style: AppTextStyles.title.copyWith(fontSize: 24, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (_limits != null && _limits!.enabled) ...[
                WithdrawLimitsCard(limits: _limits!, onCompleteKyc: _limits!.askKyc ? _openKyc : null),
                const SizedBox(height: 14),
              ],
              FlowMethodCard(
                info: _info,
                onChange: _change,
                subtitle: _info.isPlatform ? AppStrings.bettingAccount : AppStrings.instantMobileTransfer,
              ),
              const SizedBox(height: 20),
              if (_info.isPlatform)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: account),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: amount),
                  ],
                )
              else
                // The registered number (locked) beside the amount, as on Deposit.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: OwnPhoneBox(key: const Key('withdraw-own-number'), local: _ownLocal)),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: amount),
                  ],
                ),
              if ((double.tryParse(widget.availableBalance ?? '') ?? 0) > 0)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const Key('withdraw-all'),
                    onPressed: _fillAll,
                    child: Text(AppStrings.withdrawAll,
                        style: AppTextStyles.body.copyWith(color: AppColors.primaryDark, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (min != null && max != null) ...[
                const SizedBox(height: 8),
                Text(
                  AppStrings.withdrawLimits(Formatters.money(min), Formatters.money(max)),
                  key: const Key('withdraw-limits'),
                  style: AppTextStyles.muted.copyWith(fontSize: 12.5),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 24),
              PrimaryButton(
                key: const Key('withdraw-continue'),
                label: AppStrings.continueLabel,
                trailingIcon: Icons.arrow_forward_rounded,
                onPressed: _continue,
                loading: _submitting,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Account Approval Required": why, Contact Admin on WhatsApp (opened
/// already, again from here) and the admin's number to copy, and Cancel.
class _ApprovalSheet extends StatelessWidget {
  const _ApprovalSheet({required this.access, required this.onWhatsapp});

  final WithdrawalAccess access;
  final VoidCallback onWhatsapp;

  @override
  Widget build(BuildContext context) {
    final number = access.whatsapp;
    return SingleChildScrollView(
      key: const Key('withdraw-verify'),
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(color: const Color(0xFF1FA855).withOpacity(0.12), shape: BoxShape.circle),
              child: const Icon(Icons.support_agent_rounded, size: 42, color: Color(0xFF1FA855)),
            ),
          ),
          const SizedBox(height: 14),
          Text(AppStrings.verifyTitle, textAlign: TextAlign.center, style: AppTextStyles.title.copyWith(fontSize: 21)),
          const SizedBox(height: 10),
          Text(AppStrings.verifyBody, textAlign: TextAlign.center, style: AppTextStyles.body),
          if (access.reason != null && access.reason!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(access.reason!, key: const Key('verify-reason'), textAlign: TextAlign.center,
                style: AppTextStyles.muted.copyWith(color: AppColors.error)),
          ],
          const SizedBox(height: 18),
          if (access.whatsappLink() != null)
            ElevatedButton.icon(
              key: const Key('contact-admin-whatsapp'),
              onPressed: onWhatsapp,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1FA855),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              icon: const Icon(Icons.chat_rounded),
              label: Text(AppStrings.contactAdminWhatsapp, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          if (number != null && number.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder)),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(AppStrings.adminWhatsapp, style: AppTextStyles.muted),
                    Text(number, key: const Key('admin-whatsapp'), style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
                  ]),
                ),
                IconButton(
                  tooltip: AppStrings.copied(number),
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: number));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.copied(number))));
                  },
                ),
              ]),
            ),
          ],
          const SizedBox(height: 10),
          TextButton(
            key: const Key('verify-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppStrings.cancel),
          ),
        ],
      ),
    );
  }
}
