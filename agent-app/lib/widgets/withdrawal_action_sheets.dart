import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Bottom sheet collecting the payout transaction reference once the agent
/// has actually sent the withdrawal (via EVC Plus USSD/agent line, or the
/// WinWin manager app) — submitted to POST /agent/withdrawals/:id/complete.
Future<String?> showCompleteWithdrawalSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => const _SingleFieldSheet(
      title: 'Complete withdrawal',
      subtitle: 'Enter the transaction reference from the payout you just sent.',
      label: 'Transaction reference',
      submitLabel: 'Mark completed',
      minLength: 3,
    ),
  );
}

/// Bottom sheet collecting a failure reason — submitted to
/// POST /agent/withdrawals/:id/fail. Failing releases the customer's
/// reserved balance back to available; the customer is never charged for a
/// failed payout.
Future<String?> showFailWithdrawalSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => const _SingleFieldSheet(
      title: 'Mark withdrawal failed',
      subtitle: 'This releases the customer\'s reserved balance back to available. Explain why.',
      label: 'Reason',
      submitLabel: 'Mark failed',
      minLength: 3,
      maxLines: 3,
      isDestructive: true,
    ),
  );
}

class _SingleFieldSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final String label;
  final String submitLabel;
  final int minLength;
  final int maxLines;
  final bool isDestructive;

  const _SingleFieldSheet({
    required this.title,
    required this.subtitle,
    required this.label,
    required this.submitLabel,
    required this.minLength,
    this.maxLines = 1,
    this.isDestructive = false,
  });

  @override
  State<_SingleFieldSheet> createState() => _SingleFieldSheetState();
}

class _SingleFieldSheetState extends State<_SingleFieldSheet> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_controller.text.trim());
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
            Text(
              widget.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              widget.subtitle,
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _controller,
              decoration: InputDecoration(labelText: widget.label),
              maxLines: widget.maxLines,
              autofocus: true,
              textInputAction: TextInputAction.done,
              validator: (v) =>
                  (v == null || v.trim().length < widget.minLength) ? 'Required' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _submit,
              style: widget.isDestructive
                  ? ElevatedButton.styleFrom(
                      backgroundColor: AppColors.statusFailed,
                      foregroundColor: Colors.white,
                    )
                  : null,
              child: Text(widget.submitLabel),
            ),
          ],
        ),
      ),
    );
  }
}
