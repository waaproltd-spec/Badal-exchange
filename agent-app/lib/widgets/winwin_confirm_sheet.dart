import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Data collected from the agent for a manual WinWin/MobCash deposit
/// confirmation. The agent has already observed this transaction as real
/// and completed in the actual WinWin manager app — this form only records
/// what they saw; it never automates or logs into WinWin itself.
class WinwinConfirmationInput {
  final String winwinId;
  final String? depositCode;
  final String amount;
  final String mobcashRef;

  const WinwinConfirmationInput({
    required this.winwinId,
    this.depositCode,
    required this.amount,
    required this.mobcashRef,
  });
}

Future<WinwinConfirmationInput?> showWinwinConfirmSheet(BuildContext context) {
  return showModalBottomSheet<WinwinConfirmationInput>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => const _WinwinConfirmForm(),
  );
}

class _WinwinConfirmForm extends StatefulWidget {
  const _WinwinConfirmForm();

  @override
  State<_WinwinConfirmForm> createState() => _WinwinConfirmFormState();
}

class _WinwinConfirmFormState extends State<_WinwinConfirmForm> {
  final _formKey = GlobalKey<FormState>();
  final _winwinIdController = TextEditingController();
  final _depositCodeController = TextEditingController();
  final _amountController = TextEditingController();
  final _mobcashRefController = TextEditingController();

  @override
  void dispose() {
    _winwinIdController.dispose();
    _depositCodeController.dispose();
    _amountController.dispose();
    _mobcashRefController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      WinwinConfirmationInput(
        winwinId: _winwinIdController.text.trim(),
        depositCode: _depositCodeController.text.trim().isEmpty
            ? null
            : _depositCodeController.text.trim(),
        amount: _amountController.text.trim(),
        mobcashRef: _mobcashRefController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter WinWin confirmation',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            const Text(
              'Only enter details for a transaction you personally confirmed as real and '
              'completed in the WinWin manager app.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _winwinIdController,
              decoration: const InputDecoration(labelText: 'WinWin ID'),
              textInputAction: TextInputAction.next,
              validator: (v) => (v == null || v.trim().length < 3) ? 'Required' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _depositCodeController,
              decoration: const InputDecoration(labelText: 'Deposit code (optional)'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _amountController,
              decoration: const InputDecoration(labelText: 'Amount'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textInputAction: TextInputAction.next,
              validator: (v) {
                final n = double.tryParse((v ?? '').trim());
                if (n == null || n <= 0) return 'Enter a valid amount';
                return null;
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _mobcashRefController,
              decoration: const InputDecoration(labelText: 'MobCash reference'),
              textInputAction: TextInputAction.done,
              validator: (v) => (v == null || v.trim().length < 3) ? 'Required' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: _submit, child: const Text('Submit confirmation')),
          ],
        ),
      ),
    );
  }
}
