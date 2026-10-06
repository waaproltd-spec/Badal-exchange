import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../widgets/method_picker.dart';
import 'deposit_details_screen.dart';

class DepositMethodScreen extends StatelessWidget {
  const DepositMethodScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(title: Text(AppStrings.deposit, style: AppTextStyles.appBarTitle)),
      body: SafeArea(
        child: MethodPicker(
          onSelected: (option) => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DepositDetailsScreen(option: option)),
          ),
        ),
      ),
    );
  }
}
