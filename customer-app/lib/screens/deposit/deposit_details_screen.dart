import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/method_icon.dart';
import '../../widgets/payment_method_sheet.dart';
import '../../widgets/primary_button.dart';
import 'deposit_processing_screen.dart';

/// "Complete Deposit": the chosen method, who pays (phone number, or account
/// ID for betting platforms), the amount, and where to send the money --
/// for EVC Plus and eDahab as a ready-to-dial USSD code. Confirm creates the
/// deposit order (the backend credits it once the payment is verified).
class DepositDetailsScreen extends StatefulWidget {
  const DepositDetailsScreen({super.key, required this.option, this.ownPhone});

  /// The chosen method, with the numbers customers send payments to.
  final PaymentMethodOption option;

  /// The customer's registered phone, offered (locked) as the paying number.
  final String? ownPhone;

  @override
  State<DepositDetailsScreen> createState() => _DepositDetailsScreenState();
}

/// USSD "send money" codes by method: *712*number*amount# for EVC Plus,
/// *110*number*amount# for eDahab (the same codes the agent phone uses
/// for payouts).
const _sendMoneyUssd = {'evc_plus': '712', 'edahab': '110'};

/// Last 9 digits of a Somali number (drops 252 / a leading 0).
String? _localNumber(String? phone) {
  final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  return digits.length >= 9 ? digits.substring(digits.length - 9) : null;
}

class _DepositDetailsScreenState extends State<DepositDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _accountController = TextEditingController();
  final _amountController = TextEditingController();
  final _codeController = TextEditingController();
  late bool _phoneLocked;
  bool _submitting = false;
  String? _error;

  PaymentMethodInfo get _info => widget.option.info;

  @override
  void initState() {
    super.initState();
    final own = _localNumber(widget.ownPhone);
    _phoneController.text = own ?? '';
    _phoneLocked = own != null;
    for (final c in [_phoneController, _accountController, _amountController, _codeController]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _accountController.dispose();
    _amountController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String get _amountText => _amountController.text.trim();
  num? get _amount {
    final n = num.tryParse(_amountText);
    return n != null && n > 0 ? n : null;
  }

  bool get _ready =>
      _amount != null &&
      (_info.isPlatform ? _accountController.text.trim().isNotEmpty : _phoneController.text.trim().length == 9) &&
      (!_info.usesWithdrawalCode || _codeController.text.trim().isNotEmpty);

  /// The number to send the money to: the first one set up for the method.
  String? get _payTo => widget.option.depositNumbers.isEmpty ? null : widget.option.depositNumbers.first.number;

  String? get _ussd {
    final prefix = _sendMoneyUssd[_info.id];
    final to = _localNumber(_payTo);
    if (prefix == null || to == null || _amount == null) return null;
    return '*$prefix*$to*$_amountText#';
  }

  Future<void> _change() async {
    final option = await showPaymentMethodSheet(context, PaymentDirection.deposit);
    if (option == null || !mounted || option.info.id == _info.id) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => DepositDetailsScreen(option: option, ownPhone: widget.ownPhone),
    ));
  }

  Future<void> _dial(String ussd) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: ussd.replaceAll('#', '%23')));
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ussd)));
    }
  }

  Future<void> _confirm() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final api = context.read<CustomerApi>();
    try {
      // The backend checks the method and amount before anything is created.
      final quote = await api.createQuote(direction: 'deposit', method: _info.id, amount: _amountText);
      if (!mounted) return;
      final key = const Uuid().v4();
      final phone = _info.isPlatform ? null : '252${_phoneController.text.trim()}';
      final account = _info.isPlatform ? _accountController.text.trim() : null;
      final code = _info.usesWithdrawalCode ? _codeController.text.trim() : null;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DepositProcessingScreen(
          action: () => api.deposit(
            method: quote.method,
            phoneNumber: phone,
            accountId: account,
            amount: quote.amount,
            idempotencyKey: key,
            platformCode: code,
          ),
        ),
      ));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = AppStrings.somethingWentWrong);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  _RoundButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 14),
                  Expanded(child: Text(AppStrings.completeDeposit, style: AppTextStyles.title)),
                ],
              ),
              const SizedBox(height: 24),
              _MethodCard(info: _info, onChange: _change),
              const SizedBox(height: 22),
              if (_info.isPlatform) ...[
                _FieldBox(
                  label: _info.identifierLabel,
                  child: _input(_accountController, hint: _info.identifierHint, keyboard: TextInputType.number,
                      validator: (v) => (v ?? '').trim().isEmpty ? AppStrings.enterAccountId : null),
                ),
                const SizedBox(height: 16),
                _amountBox(),
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 13, child: _phoneBox()),
                    const SizedBox(width: 10),
                    Expanded(flex: 7, child: _amountBox()),
                  ],
                ),
              if (_info.usesWithdrawalCode) ...[
                const SizedBox(height: 16),
                _FieldBox(
                  label: AppStrings.withdrawalCodeLabel(_info.label),
                  child: _input(_codeController, hint: AppStrings.withdrawalCodeHint(_info.label), validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return AppStrings.enterWithdrawalCode;
                    if (t.length > 64 || t.contains(RegExp(r'\s'))) return AppStrings.enterCodeExactly;
                    return null;
                  }),
                ),
                const SizedBox(height: 10),
                Text(AppStrings.depositCodeFlowHint(_info.label), style: AppTextStyles.muted.copyWith(fontSize: 13)),
              ],
              if (_amount != null && _payTo != null) ...[
                const SizedBox(height: 22),
                _PayToCard(
                  ussd: _ussd,
                  number: _payTo!,
                  label: widget.option.depositNumbers.first.label,
                  onDial: _dial,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
              ],
              const SizedBox(height: 24),
              PrimaryButton(
                key: const Key('confirm-deposit'),
                label: AppStrings.confirmDeposit,
                trailingIcon: Icons.arrow_forward_rounded,
                onPressed: _ready && !_submitting ? _confirm : null,
                loading: _submitting,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phoneBox() => _FieldBox(
        label: AppStrings.phoneNumber,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 8),
              child: Text('+252', style: AppTextStyles.body.copyWith(color: AppColors.textMuted)),
            ),
            Container(width: 1, height: 24, color: AppColors.fieldBorder),
            Expanded(
              child: _input(
                _phoneController,
                key: const Key('deposit-phone'),
                hint: '61XXXXXXX',
                keyboard: TextInputType.phone,
                readOnly: _phoneLocked,
                formatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(9)],
                validator: (v) => (v ?? '').trim().length == 9 ? null : AppStrings.enterNineDigits,
              ),
            ),
            if (widget.ownPhone != null)
              IconButton(
                key: const Key('phone-lock'),
                tooltip: _phoneLocked ? AppStrings.useAnotherNumber : null,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.only(right: 6),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                icon: Icon(_phoneLocked ? Icons.lock_outline_rounded : Icons.lock_open_rounded,
                    color: AppColors.textMuted, size: 20),
                onPressed: () => setState(() => _phoneLocked = !_phoneLocked),
              ),
          ],
        ),
      );

  Widget _amountBox() => _FieldBox(
        label: AppStrings.amountShort,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: Text('\$', style: AppTextStyles.title.copyWith(color: AppColors.primary)),
            ),
            Expanded(
              child: _input(
                _amountController,
                key: const Key('deposit-amount'),
                hint: '0.00',
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                formatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                validator: (v) => _amount == null ? AppStrings.enterValidAmount : null,
                valueColor: AppColors.statusCompleted,
              ),
            ),
          ],
        ),
      );

  Widget _input(
    TextEditingController controller, {
    Key? key,
    String? hint,
    TextInputType? keyboard,
    bool readOnly = false,
    List<TextInputFormatter>? formatters,
    String? Function(String?)? validator,
    Color? valueColor,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      keyboardType: keyboard,
      readOnly: readOnly,
      inputFormatters: formatters,
      validator: validator,
      style: AppTextStyles.fieldValue.copyWith(
        fontWeight: FontWeight.w800,
        color: readOnly ? AppColors.textPrimary.withOpacity(0.8) : valueColor,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppTextStyles.fieldValue.copyWith(color: AppColors.textMuted, fontWeight: FontWeight.w500),
        border: InputBorder.none,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 18),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 2,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon, color: AppColors.textPrimary)),
      ),
    );
  }
}

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.info, required this.onChange});

  final PaymentMethodInfo info;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.cardBorder, width: 1.2),
      ),
      child: Row(
        children: [
          MethodIcon(method: info.id, size: 50),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(info.label.toUpperCase(), style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                  info.isPlatform ? AppStrings.bettingAccount : AppStrings.instantMobileTransfer,
                  style: AppTextStyles.muted,
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('change-method'),
            onPressed: onChange,
            child: Text(AppStrings.change,
                style: AppTextStyles.body.copyWith(color: AppColors.primaryDark, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

/// Uppercase label above a white rounded box (the design's input fields).
class _FieldBox extends StatelessWidget {
  const _FieldBox({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppTextStyles.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(minHeight: 60),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.fieldBorder, width: 1.5),
          ),
          child: child,
        ),
      ],
    );
  }
}

/// Where to send the money: a USSD code to dial (EVC Plus, eDahab), or the
/// number to copy.
class _PayToCard extends StatelessWidget {
  const _PayToCard({required this.ussd, required this.number, required this.label, required this.onDial});

  final String? ussd;
  final String number;
  final String? label;
  final ValueChanged<String> onDial;

  @override
  Widget build(BuildContext context) {
    final text = ussd ?? number;
    return Container(
      key: const Key('pay-to-card'),
      padding: const EdgeInsets.fromLTRB(20, 16, 14, 16),
      decoration: BoxDecoration(
        color: AppColors.primaryTint,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withOpacity(0.25), width: 1.2),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.sendMoneyToAccount.toUpperCase(), style: AppTextStyles.label),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(text,
                      style: AppTextStyles.title.copyWith(color: AppColors.primaryDark, fontWeight: FontWeight.w800)),
                ),
                if (ussd == null && (label ?? '').isNotEmpty)
                  Text(label!, style: AppTextStyles.muted.copyWith(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Material(
            color: AppColors.primaryDark,
            shape: const CircleBorder(),
            elevation: 3,
            child: IconButton(
              key: const Key('pay-to-action'),
              tooltip: ussd != null ? AppStrings.dial : AppStrings.copy,
              icon: Icon(ussd != null ? Icons.call_rounded : Icons.copy_rounded, color: Colors.white),
              onPressed: () {
                if (ussd != null) {
                  onDial(ussd!);
                } else {
                  Clipboard.setData(ClipboardData(text: number));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppStrings.copied(number))));
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
