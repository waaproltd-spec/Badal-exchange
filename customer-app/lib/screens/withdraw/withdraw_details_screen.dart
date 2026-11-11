import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../services/deposit_voice.dart';
import '../../widgets/withdrawal_approval_sheet.dart';

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
import '../../models/payment_numbers.dart';
import '../../widgets/pay_number_box.dart';
import '../../widgets/payment_method_sheet.dart';
import '../../widgets/primary_button.dart';
import 'withdraw_confirm_screen.dart';

/// Collects the amount (plus the account ID for betting platforms), then
/// fetches a quote (which also enforces min/max withdrawal limits
/// server-side) before moving to confirmation. Mobile money is always paid
/// out to the customer's registered login number (the backend enforces
/// it), so there is no phone field.
class WithdrawDetailsScreen extends StatefulWidget {
  const WithdrawDetailsScreen({super.key, required this.method, this.ownPhone, this.option, this.availableBalance, this.voice});

  /// The Somali voice instruction (replaceable in tests).
  final DepositVoice? voice;

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
  DepositVoice? _voice;
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

  /// The available balance is known and is not above $0.00: nothing to withdraw, so the approval popup (which
  /// sends the customer to the administration) is not shown; the balance message is.
  bool get _noBalance {
    final b = double.tryParse(widget.availableBalance ?? '');
    return b != null && b <= 0;
  }

  /// Another number an admin lets this customer use (loaded once), and the
  /// 9 digits chosen: the registered number unless the customer changes it.
  PaymentNumbers _numbers = PaymentNumbers.none;
  final TextEditingController _phoneController = TextEditingController();

  /// The 9 digits typed in the number box; the registered number while the box
  /// is empty; null while the typing is not complete.
  String? get _phoneLocal {
    final typed = _phoneController.text;
    if (typed.isEmpty) return _ownLocal;
    return typed.length == 9 ? typed : null;
  }

  @override
  void initState() {
    super.initState();
    _checkAccess();
    _loadLimits();
    if (!_info.isPlatform) {
      _loadNumbers();
      // Mobile money (EVC Plus, Golis, eDahab, Zaad): the voice speaks on open; the customer still taps Continue.
      _voice = widget.voice ?? AudioDepositVoice.withdraw();
      _voice!.play();
    }
  }

  Future<void> _loadNumbers() async {
    final n = await context.read<CustomerApi>().getPaymentNumbers();
    if (mounted) setState(() => _numbers = n);
  }

  Future<void> _loadLimits() async {
    final limits = await context.read<CustomerApi>().getWithdrawLimits();
    if (mounted) setState(() => _limits = limits);
  }

  /// Why [amount] cannot be withdrawn now, or null (the server decides anyway).
  String? _limitProblem(double amount) {
    final l = _limits;
    if (l == null || !l.enabled) return null;
    if (l.reached || !l.canWithdraw) {
      return l.warning == 'monthly_reached' ? PaymentErrors.limitMonthlyReached : PaymentErrors.limitDailyReached;
    }
    if (amount > l.availableValue + 0.0001) return PaymentErrors.limitExceeds(l.availableNow);
    return null;
  }

  /// Before the first withdrawal an admin approves the account.
  Future<void> _checkAccess() async {
    final access = await context.read<CustomerApi>().getWithdrawalAccess();
    if (mounted) setState(() => _access = access);
  }

  Uri? get _whatsappLink => _access?.whatsappLink();

  /// First withdrawal, account not approved: WhatsApp opens with the
  /// message for the admin, and the sheet says why. Nothing is created and
  /// nothing is taken (the server refuses it anyway).
  Future<void> _askForApproval() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WithdrawalApprovalSheet(
        whatsappLink: _whatsappLink,
        customerId: _access?.accountId,
        reason: _access?.reason,
      ),
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
    _voice?.stop();
    _voice?.dispose();
    _phoneController.dispose();
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
      if (_noBalance) {
        setState(() => _error = AppStrings.insufficientBalance);
        return;
      }
      await _askForApproval();
      return;
    }
    if (!_info.isPlatform && _phoneLocal == null) {
      setState(() => _error = _ownLocal == null ? AppStrings.noRegisteredNumber : AppStrings.enterNineDigits);
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
            phoneNumber: _info.isPlatform ? null : '252$_phoneLocal',
            accountId: _info.isPlatform ? _identifierController.text.trim() : null,
          ),
        ),
      );
    } on ApiException catch (e) {
      if (e.code == 'WITHDRAWAL_VERIFICATION_REQUIRED') {
        await _checkAccess();
        if (mounted && _blocked) {
          if (_noBalance) {
            setState(() => _error = AppStrings.insufficientBalance);
          } else {
            await _askForApproval();
          }
        }
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
                    Expanded(
                      flex: 3,
                      child: PayNumberBox(
                        fieldKey: const Key('withdraw-own-number'),
                        method: widget.method,
                        ownLocal: _ownLocal,
                        numbers: _numbers,
                        controller: _phoneController,
                      ),
                    ),
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
