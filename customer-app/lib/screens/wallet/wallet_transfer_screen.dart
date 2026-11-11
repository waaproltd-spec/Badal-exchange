import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/wallet_transfer.dart';
import '../../state/wallet_provider.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';
import '../../widgets/primary_button.dart';
import '../security/pin_pad.dart';

/// Wallet -> Send Money: a free transfer from the customer's own wallet to another customer's wallet.
///   1. the recipient's Wallet ID, 2. Verify: the name is shown, 3. the amount, 4. the 4-digit Wallet PIN, 5. Confirm & Send.
/// Everything is decided by the server (the balance, the PIN, the lock after 5 wrong tries, no duplicates, no fee); this screen
/// only collects the answers and shows the result.
class WalletTransferScreen extends StatefulWidget {
  const WalletTransferScreen({super.key});

  @override
  State<WalletTransferScreen> createState() => _WalletTransferScreenState();
}

class _WalletTransferScreenState extends State<WalletTransferScreen> {
  static final _walletIdPattern = RegExp(r'^BE[0-9]{6}$');

  final _walletController = TextEditingController();
  final _amountController = TextEditingController();
  TransferRecipient? _recipient;
  String? _recipientError;
  bool _verifying = false;
  List<WalletTransfer> _history = const [];
  WalletTransfer? _done;

  // One key per intended transfer: a retry (a bad connection, a double tap) never sends twice.
  String _key = const Uuid().v4();

  @override
  void initState() {
    super.initState();
    _walletController.addListener(_walletChanged);
    _amountController.addListener(() => setState(() {}));
    _loadHistory();
  }

  @override
  void dispose() {
    _walletController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  CustomerApi get _api => context.read<CustomerApi>();

  Future<void> _loadHistory() async {
    try {
      final list = await _api.getWalletTransfers();
      if (mounted) setState(() => _history = list);
    } catch (_) {
      // The history is secondary: the form still works.
    }
  }

  bool _resetting = false;

  void _walletChanged() {
    if (_resetting) return;
    // Another ID: the earlier name no longer counts (and Verify follows what is typed).
    setState(() {
      _recipient = null;
      _recipientError = null;
      _done = null;
    });
  }

  String get _walletId => _walletController.text.trim().toUpperCase();
  bool get _walletIdValid => _walletIdPattern.hasMatch(_walletId);

  Future<void> _verify() async {
    if (!_walletIdValid || _verifying) return;
    setState(() {
      _verifying = true;
      _recipientError = null;
    });
    try {
      final r = await _api.lookupTransferRecipient(_walletId);
      if (!mounted) return;
      setState(() {
        if (!r.found) {
          _recipient = null;
          _recipientError = AppStrings.recipientNotFound;
        } else if (r.self) {
          _recipient = null;
          _recipientError = AppStrings.ownWalletId;
        } else {
          _recipient = r;
        }
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _recipientError = e.message);
    } catch (_) {
      if (mounted) setState(() => _recipientError = AppStrings.couldNotSend);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  bool get _amountValid {
    final v = double.tryParse(_amountController.text.trim());
    return v != null && v > 0 && RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(_amountController.text.trim());
  }

  /// Only to enable the button: the server checks the real balance.
  bool get _amountWithinBalance {
    final balance = double.tryParse(context.read<WalletProvider>().wallet?.availableBalance ?? '');
    final v = double.tryParse(_amountController.text.trim());
    return balance == null || v == null || v <= balance;
  }

  bool get _canSend => _recipient != null && _amountValid && _amountWithinBalance;

  Future<void> _send() async {
    if (!_canSend) return;
    final messenger = ScaffoldMessenger.of(context);
    var status = await _api.getWalletPinStatus().catchError((_) => const WalletPinStatus(hasPin: true));
    if (!mounted) return;
    if (!status.hasPin) {
      final created = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _CreatePinSheet(api: _api),
      );
      if (created != true || !mounted) return;
    }
    final amount = _amountController.text.trim();
    final recipient = _recipient!;
    final outcome = await showModalBottomSheet<TransferOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ConfirmSheet(
        api: _api,
        recipient: recipient,
        amount: amount,
        idempotencyKey: _key,
      ),
    );
    if (outcome == null || !outcome.ok || !mounted) return;
    _resetting = true; // clearing the form is not "another ID": keep the result on screen
    _walletController.clear();
    _amountController.clear();
    _resetting = false;
    setState(() {
      _done = outcome.transfer;
      _recipient = null;
      _key = const Uuid().v4();
    });
    context.read<WalletProvider?>()?.load(silent: true); // the balance, at once
    messenger.showSnackBar(SnackBar(content: Text(AppStrings.transferSent)));
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletProvider>().wallet;
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.sendMoney, style: AppTextStyles.appBarTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(gradient: AppColors.cardGradient, borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              Icon(Icons.account_balance_wallet_rounded, color: Colors.white.withOpacity(0.85)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(AppStrings.availableBalance, style: AppTextStyles.muted.copyWith(color: Colors.white.withOpacity(0.85))),
              ),
              Text(Formatters.money(wallet?.availableBalance ?? '0.00'),
                  key: const Key('transfer-balance'),
                  style: AppTextStyles.fieldValue.copyWith(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            ]),
          ),
          const SizedBox(height: 18),
          Text(AppStrings.recipientWalletId, style: AppTextStyles.muted),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                key: const Key('transfer-wallet-id'),
                controller: _walletController,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                maxLength: 8,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]'))],
                decoration: InputDecoration(hintText: 'BE592850', counterText: '', errorText: _recipientError),
                onSubmitted: (_) => _verify(),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const Key('transfer-verify'),
                onPressed: _walletIdValid && !_verifying ? _verify : null,
                child: _verifying
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(AppStrings.verifyRecipient),
              ),
            ),
          ]),
          if (_recipient != null) ...[
            const SizedBox(height: 10),
            Container(
              key: const Key('transfer-recipient'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.success.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.success.withOpacity(0.5)),
              ),
              child: Row(children: [
                const Icon(Icons.verified_rounded, color: AppColors.success),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_recipient!.name ?? '', key: const Key('transfer-recipient-name'), style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
                    Text(_recipient!.walletId ?? '', style: AppTextStyles.muted),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('transfer-amount'),
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,7}(\.\d{0,2})?'))],
              decoration: InputDecoration(labelText: AppStrings.amount, prefixText: '\$ '),
            ),
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.check_circle_rounded, size: 16, color: AppColors.success),
              const SizedBox(width: 6),
              Expanded(child: Text(AppStrings.transferFree, key: const Key('transfer-free'), style: AppTextStyles.muted)),
            ]),
            if (_amountValid && !_amountWithinBalance)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(AppStrings.notEnoughBalance, key: const Key('transfer-too-much'), style: const TextStyle(color: AppColors.error)),
              ),
            const SizedBox(height: 16),
            PrimaryButton(key: const Key('transfer-send'), label: AppStrings.sendButton, onPressed: _canSend ? _send : null),
          ],
          if (_done != null) ...[
            const SizedBox(height: 16),
            _DonePanel(transfer: _done!),
          ],
          const SizedBox(height: 26),
          Text(AppStrings.recentTransfers, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_history.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(AppStrings.noTransfers, key: const Key('transfer-none'), style: AppTextStyles.muted))
          else
            for (final t in _history) _TransferTile(key: Key('transfer-${t.id}'), transfer: t),
        ],
      ),
    );
  }
}

class _DonePanel extends StatelessWidget {
  const _DonePanel({required this.transfer});
  final WalletTransfer transfer;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('transfer-done'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.success.withOpacity(0.12), borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.check_circle_rounded, color: AppColors.success),
            const SizedBox(width: 8),
            Text(AppStrings.transferSent, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          Text('${Formatters.money(transfer.amount)} → ${transfer.counterpartName} (${transfer.counterpartWalletId})', style: AppTextStyles.body),
          Text('${AppStrings.reference}: ${transfer.reference}', style: AppTextStyles.muted),
          Text('${AppStrings.newBalance}: ${Formatters.money(transfer.balanceAfter)}', style: AppTextStyles.muted),
        ]),
      );
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({super.key, required this.transfer});
  final WalletTransfer transfer;

  @override
  Widget build(BuildContext context) {
    final sent = transfer.sent;
    final d = transfer.createdAt;
    String two(int v) => v.toString().padLeft(2, '0');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.primaryTint, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(sent ? Icons.north_east_rounded : Icons.south_west_rounded, color: sent ? AppColors.error : AppColors.success),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(sent ? AppStrings.sentTo(transfer.counterpartName) : AppStrings.receivedFrom(transfer.counterpartName),
                style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w700)),
            Text('${transfer.counterpartWalletId} · ${transfer.reference} · ${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}', style: AppTextStyles.muted.copyWith(fontSize: 12)),
          ]),
        ),
        Text('${sent ? '-' : '+'}${Formatters.money(transfer.amount)}',
            style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, color: sent ? AppColors.error : AppColors.success)),
      ]),
    );
  }
}

const _sheetDecoration = BoxDecoration(
  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3A0353), Color(0xFF2B0A42)]),
  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
);

/// First time: create the Wallet PIN (4 digits, twice) and confirm it with the account password.
class _CreatePinSheet extends StatefulWidget {
  const _CreatePinSheet({required this.api});
  final CustomerApi api;

  @override
  State<_CreatePinSheet> createState() => _CreatePinSheetState();
}

class _CreatePinSheetState extends State<_CreatePinSheet> {
  final _pin = TextEditingController();
  final _again = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _again.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_pin.text.length != 4 || _password.text.isEmpty) return;
    if (_pin.text != _again.text) {
      setState(() => _error = AppStrings.pinsDoNotMatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.api.setWalletPin(pin: _pin.text, password: _password.text);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = AppStrings.wrongPassword);
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.couldNotSend);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _decoration(String label) => InputDecoration(
        labelText: label,
        counterText: '',
        labelStyle: const TextStyle(color: Colors.white70),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.white38)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Colors.white)),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('create-pin-sheet'),
      decoration: _sheetDecoration,
      padding: EdgeInsets.fromLTRB(20, 24, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(AppStrings.createWalletPin, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(AppStrings.walletPinHelp, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            TextField(
              key: const Key('new-pin'),
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              style: const TextStyle(color: Colors.white),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _decoration(AppStrings.walletPinField),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('new-pin-again'),
              controller: _again,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 4,
              style: const TextStyle(color: Colors.white),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _decoration(AppStrings.walletPinAgain),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('new-pin-password'),
              controller: _password,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: _decoration(AppStrings.password),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, key: const Key('create-pin-error'), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFFB3C1), fontWeight: FontWeight.w700)),
              ),
            const SizedBox(height: 16),
            PrimaryButton(key: const Key('save-pin'), label: AppStrings.savePin, loading: _busy, onPressed: _busy ? null : _save),
          ]),
        ),
      ),
    );
  }
}

/// The last look (who, how much, free) and the 4-digit Wallet PIN. A wrong PIN says how many tries are left; five lock it.
class _ConfirmSheet extends StatefulWidget {
  const _ConfirmSheet({required this.api, required this.recipient, required this.amount, required this.idempotencyKey});

  final CustomerApi api;
  final TransferRecipient recipient;
  final String amount;
  final String idempotencyKey;

  @override
  State<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<_ConfirmSheet> {
  static const int _pinLength = 4;
  String _pin = '';
  String? _error;
  bool _busy = false;
  bool _locked = false;

  void _digit(String d) {
    if (_busy || _locked || _pin.length >= _pinLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _backspace() {
    if (_busy || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  Future<void> _confirm() async {
    if (_pin.length != _pinLength || _busy || _locked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await widget.api.sendWalletTransfer(
        toWallet: widget.recipient.walletId ?? '',
        amount: widget.amount,
        pin: _pin,
        idempotencyKey: widget.idempotencyKey,
      );
      if (!mounted) return;
      if (outcome.ok) {
        Navigator.of(context).pop(outcome);
        return;
      }
      setState(() {
        _pin = '';
        if (outcome.code == 'PIN_LOCKED') {
          _locked = true;
          _error = AppStrings.walletPinLocked;
        } else {
          _error = AppStrings.wrongWalletPin(outcome.attemptsLeft ?? 0);
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _pin = '';
        _error = e.code == 'INSUFFICIENT_BALANCE' ? AppStrings.notEnoughBalance : e.message;
      });
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.couldNotSend);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('confirm-transfer-sheet'),
      decoration: _sheetDecoration,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(AppStrings.confirmTransfer, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Text(Formatters.money(widget.amount),
                key: const Key('confirm-amount'), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFF8D299), fontSize: 34, fontWeight: FontWeight.w800)),
            Text('${widget.recipient.name ?? ''} · ${widget.recipient.walletId ?? ''}',
                key: const Key('confirm-recipient'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(AppStrings.transferFree, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 14),
            Text(AppStrings.enterWalletPin, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            Center(child: PinPad(entered: _pin.length, length: _pinLength, onDigit: _digit, onBackspace: _backspace, error: _error, enabled: !_busy && !_locked)),
            const SizedBox(height: 8),
            PrimaryButton(
              key: const Key('transfer-confirm'),
              label: AppStrings.confirmAndSend,
              loading: _busy,
              onPressed: _pin.length == _pinLength && !_busy && !_locked ? _confirm : null,
            ),
          ]),
        ),
      ),
    );
  }
}
