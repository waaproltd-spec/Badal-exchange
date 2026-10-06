import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_exception.dart';
import '../api/customer_api.dart';
import '../l10n/strings.dart';
import '../models/payment_method.dart';
import '../theme/colors.dart';
import '../theme/text_styles.dart';
import 'method_icon.dart';

/// "Choose a method" screen body: every payment method the backend currently
/// offers, as a 3-column grid (mobile money first, then betting platforms).
/// Methods switched OFF from the Agent App don't appear.
class MethodPicker extends StatefulWidget {
  const MethodPicker({super.key, required this.onSelected});

  final ValueChanged<PaymentMethodOption> onSelected;

  @override
  State<MethodPicker> createState() => _MethodPickerState();
}

class _MethodPickerState extends State<MethodPicker> {
  late Future<List<PaymentMethodOption>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<CustomerApi>().getPaymentMethods();
  }

  void _retry() => setState(() => _future = context.read<CustomerApi>().getPaymentMethods());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PaymentMethodOption>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: AppColors.primary));
        }
        if (snapshot.hasError) {
          final error = snapshot.error;
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error is ApiException ? error.message : 'Could not load payment methods.',
                  style: AppTextStyles.muted,
                  textAlign: TextAlign.center,
                ),
                TextButton(onPressed: _retry, child: const Text(AppStrings.tryAgain)),
              ],
            ),
          );
        }
        final methods = snapshot.data!;
        final mobile = methods.where((m) => !m.info.isPlatform).toList();
        final platforms = methods.where((m) => m.info.isPlatform).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            Text(AppStrings.chooseMethod, style: AppTextStyles.headline),
            if (methods.isEmpty) ...[
              const SizedBox(height: 24),
              Text('No payment methods are available right now.', style: AppTextStyles.muted),
            ],
            if (mobile.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(AppStrings.mobileMoney.toUpperCase(), style: AppTextStyles.label),
              const SizedBox(height: 10),
              _Grid(methods: mobile, onSelected: widget.onSelected),
            ],
            if (platforms.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(AppStrings.bettingPlatforms.toUpperCase(), style: AppTextStyles.label),
              const SizedBox(height: 10),
              _Grid(methods: platforms, onSelected: widget.onSelected),
            ],
          ],
        );
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.methods, required this.onSelected});

  final List<PaymentMethodOption> methods;
  final ValueChanged<PaymentMethodOption> onSelected;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.95,
      children: [
        for (final m in methods)
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => onSelected(m),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.cardBorder, width: 1.5),
                ),
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    MethodIcon(method: m.info.id, size: 46),
                    const SizedBox(height: 10),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        m.info.label,
                        style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
