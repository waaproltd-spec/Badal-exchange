import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/payment_method.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/payment_errors.dart';
import '../../utils/formatters.dart';
import '../../utils/ussd.dart';
import '../../widgets/flow_header.dart';
import '../../models/payment_numbers.dart';
import '../../widgets/pay_number_box.dart';
import '../../widgets/payment_location_card.dart';
import '../../widgets/payment_method_sheet.dart';
import '../../widgets/primary_button.dart';
import 'deposit_processing_screen.dart';

/// What one deposit may be, shown under the amount and checked before sending.
const kDepositMin = '0.01';
const kDepositMax = '4000.00';

/// "Complete Deposit": the chosen method, the amount (plus the account ID for
/// betting platforms), and where to send the money -- for EVC Plus and
/// eDahab as a ready-to-dial USSD code. Mobile money is always paid from
/// the customer's registered login number (the backend enforces it), so
/// there is no phone field. Confirm creates the deposit order; the backend
/// credits it once the payment from that number is verified.
class DepositDetailsScreen extends StatefulWidget {
  const DepositDetailsScreen({super.key, required this.option, this.ownPhone});

  /// The chosen method, with the numbers customers send payments to.
  final PaymentMethodOption option;

  /// The customer's registered login phone: the only number mobile money
  /// is paid from.
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
  final _accountController = TextEditingController();
  final _amountController = TextEditingController();
  final _codeController = TextEditingController();
  bool _submitting = false;
  String? _error;

  /// What was last sent to the server about this form (Unconfirmed Deposits).
  String? _tracked;
  Future<void>? _tracking;
  late final CustomerApi _api;

  /// Another number an admin lets this customer use (loaded once), and the
  /// 9 digits chosen: the registered number unless the customer changes it.
  PaymentNumbers _numbers = PaymentNumbers.none;
  String? _phoneLocal;


  PaymentMethodInfo get _info => widget.option.info;

  @override
  void initState() {
    super.initState();
    for (final c in [_accountController, _amountController, _codeController]) {
      c.addListener(() => setState(() {}));
    }
    _api = context.read<CustomerApi>();
    _phoneLocal = _ownLocal;
    if (!_info.isPlatform) _loadNumbers();
    _amountController.addListener(_track);
    _accountController.addListener(_track);
    if (_cashDesk) _fillSavedAccount();
  }

  Future<void> _loadNumbers() async {
    final n = await _api.getPaymentNumbers();
    if (mounted) setState(() => _numbers = n);
  }

  /// Cash desk: the account ID starts as the one the customer used last
  /// time with this platform; they can change it.
  Future<void> _fillSavedAccount() async {
    try {
      final saved = await context.read<CustomerApi>().getPlatformAccount(_info.id);
      if (mounted && saved != null && _accountController.text.isEmpty) _accountController.text = saved;
    } catch (_) {
      // Left empty: the customer types it.
    }
  }

  /// The form as it is now: a valid amount (or, for a cash desk, an
  /// account ID) is recorded as a deposit the customer has not confirmed.
  void _track() {
    final amount = _cashDesk ? null : (_amount == null ? null : _amountText);
    final account = _info.isPlatform ? _accountController.text.trim() : null;
    if (amount == null && (account == null || account.isEmpty)) return;
    final now = '$amount|$account';
    if (now == _tracked) return;
    _tracked = now;
    _tracking = _api.trackDepositDraft(method: _info.id, amount: amount, accountId: account);
  }

  @override
  void dispose() {
    _accountController.dispose();
    _amountController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String get _amountText => _amountController.text.trim();
  num? get _amount {
    final n = num.tryParse(_amountText);
    return n != null && n >= num.parse(kDepositMin) && n <= num.parse(kDepositMax) ? n : null;
  }

  /// 888STARZ / 1XBET: the customer withdraws to our cash desk in the
  /// platform and gives us the code; the platform says the amount.
  bool get _cashDesk => _info.usesWithdrawalCode;

  bool get _ready =>
      (_cashDesk || _amount != null) &&
      (_info.isPlatform ? _accountController.text.trim().isNotEmpty : _phoneLocal != null) &&
      (!_info.usesWithdrawalCode || _codeController.text.trim().isNotEmpty);

  String? get _ownLocal => _localNumber(widget.ownPhone);

  /// The number to send the money to: the first one set up for the method.
  String? get _payTo => widget.option.depositNumbers.isEmpty ? null : widget.option.depositNumbers.first.number;

  /// The merchant code when the method has one switched on, otherwise the
  /// carrier's send-money code to the deposit number.
  String? get _ussd {
    final merchant = widget.option.merchantUssd;
    if (merchant != null) return _amount == null ? null : merchant.replaceAll('{amount}', ussdAmount(_amountText));
    final prefix = _sendMoneyUssd[_info.id];
    final to = _localNumber(_payTo);
    if (prefix == null || to == null || _amount == null) return null;
    return '*$prefix*$to*${ussdAmount(_amountText)}#';
  }

  Future<void> _change() async {
    final option = await showPaymentMethodSheet(context, PaymentDirection.deposit, ownPhone: widget.ownPhone);
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
    // The form is recorded before the request, so the request is tied to it.
    await _tracking;
    if (!mounted) return;
    try {
      // The backend checks the method and amount before anything is created.
      // A cash-desk deposit has no amount: the platform says it.
      final amount = _cashDesk
          ? null
          : (await api.createQuote(direction: 'deposit', method: _info.id, amount: _amountText)).amount;
      if (!mounted) return;
      final key = const Uuid().v4();
      final phone = _info.isPlatform ? null : '252$_phoneLocal';
      final account = _info.isPlatform ? _accountController.text.trim() : null;
      final code = _info.usesWithdrawalCode ? _codeController.text.trim() : null;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DepositProcessingScreen(
          method: _info.id,
          amount: amount,
          action: () => api.deposit(
            method: _info.id,
            phoneNumber: phone,
            accountId: account,
            amount: amount,
            idempotencyKey: key,
            platformCode: code,
          ),
        ),
      ));
    } catch (e) {
      setState(() => _error = PaymentErrors.handle(api, e, isDeposit: true, method: _info.id, amount: _amountText));
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
                  RoundIconButton(icon: Icons.chevron_left_rounded, onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 14),
                  Expanded(child: Text(AppStrings.completeDeposit, style: AppTextStyles.title)),
                ],
              ),
              const SizedBox(height: 24),
              FlowMethodCard(info: _info, onChange: _change),
              const SizedBox(height: 22),
              if (_cashDesk) ...[
                _FieldBox(
                  key: const Key('account-id'),
                  label: _info.identifierLabel,
                  child: _input(_accountController,
                      hint: _info.identifierHint,
                      keyboard: TextInputType.number,
                      validator: (v) => (v ?? '').trim().isEmpty ? AppStrings.enterAccountId : null),
                ),
                const SizedBox(height: 16),
                _FieldBox(
                  label: AppStrings.paymentCode,
                  child: _input(_codeController, key: const Key('payment-code'), hint: AppStrings.enterPaymentCode,
                      validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return AppStrings.enterWithdrawalCode;
                    if (t.length > 64 || t.contains(RegExp(r'\s'))) return AppStrings.enterCodeExactly;
                    return null;
                  }),
                ),
              ] else if (_info.isPlatform) ...[
                _FieldBox(
                  label: _info.identifierLabel,
                  child: _input(_accountController,
                      hint: _info.identifierHint,
                      keyboard: TextInputType.number,
                      validator: (v) => (v ?? '').trim().isEmpty ? AppStrings.enterAccountId : null),
                ),
                const SizedBox(height: 16),
                _amountBox(),
              ] else ...[
                // The registered number (locked) beside the amount, then the limits.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: PayNumberBox(
                        fieldKey: const Key('own-number'),
                        method: _info.id,
                        ownLocal: _ownLocal,
                        numbers: _numbers,
                        onChanged: (v) => setState(() => _phoneLocal = v),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: _amountBox()),
                  ],
                ),
                if (_ownLocal == null) ...[
                  const SizedBox(height: 8),
                  Text(AppStrings.noRegisteredNumber, style: AppTextStyles.muted.copyWith(color: AppColors.error)),
                ],
                const SizedBox(height: 10),
                _LimitsLine(min: Formatters.money(kDepositMin), max: Formatters.money(kDepositMax)),
              ],
              if (!_cashDesk && _amount != null && (_payTo != null || widget.option.merchantUssd != null)) ...[
                const SizedBox(height: 22),
                _PayToCard(
                  ussd: _ussd,
                  number: _payTo ?? '',
                  label: widget.option.merchantUssd != null ? null : widget.option.depositNumbers.first.label,
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
              if (_cashDesk && widget.option.hasPaymentLocation) ...[
                const SizedBox(height: 16),
                PaymentLocationCard(city: widget.option.paymentCity, street: widget.option.paymentStreet),
              ],
            ],
          ),
        ),
      ),
    );
  }

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

/// "Minimum deposit is $0.01, maximum is $4000.00", the amounts in bold.
class _LimitsLine extends StatelessWidget {
  const _LimitsLine({required this.min, required this.max});

  final String min;
  final String max;

  @override
  Widget build(BuildContext context) {
    final base = AppTextStyles.muted.copyWith(fontSize: 12.5);
    final bold = base.copyWith(fontWeight: FontWeight.w800, color: AppColors.textPrimary);
    final (a, b) = AppStrings.depositLimitsParts;
    return Text.rich(
      key: const Key('deposit-limits'),
      TextSpan(style: base, children: [
        TextSpan(text: a),
        TextSpan(text: min, style: bold),
        TextSpan(text: b),
        TextSpan(text: max, style: bold),
      ]),
    );
  }
}

/// Uppercase label above a white rounded box (the design's input fields).
class _FieldBox extends StatelessWidget {
  const _FieldBox({super.key, required this.label, required this.child});

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
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.fieldBorder, width: 1.5),
          ),
          child: child,
        ),
      ],
    );
  }
}

/// The cash desk to withdraw to in the betting platform: city and street
/// (a deposit number set up in the Agent App), with the street to copy.
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
            color: AppColors.purple,
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
