/// Flat customer-facing string table.
///
/// This intentionally stays a simple key table (not full `flutter intl`
/// tooling) per product guidance. English is the default; a parallel
/// Somali map can be added later (e.g. `AppStringsSo`) and swapped in via
/// a locale check without restructuring call sites, since every screen
/// already reads through `AppStrings.*` instead of inline literals.
class AppStrings {
  AppStrings._();

  static const String appName = 'Badal Exchange';

  // Auth
  static const String login = 'Log In';
  static const String register = 'Create Account';
  static const String phoneNumber = 'Phone Number';
  static const String password = 'Password';
  static const String fullName = 'Full Name';
  static const String confirmPassword = 'Confirm Password';
  static const String noAccount = "Don't have an account?";
  static const String haveAccount = 'Already have an account?';
  static const String logout = 'Log Out';

  // Home
  static const String home = 'Home';
  static const String availableBalance = 'Available Balance';
  static const String deposit = 'Deposit';
  static const String withdraw = 'Withdraw';

  // Method picker
  static const String chooseMethod = 'Choose a method';
  static const String evcPlus = 'EVC Plus';
  static const String winwin = '888STARZ';

  // Deposit / withdraw shared
  static const String amount = 'Amount (USD)';
  static const String continueLabel = 'Continue';
  static const String confirm = 'Confirm';
  static const String rate = 'Exchange Rate';
  static const String fee = 'Fee';
  static const String netAmount = 'You will receive';
  static const String totalDeducted = 'Total Deducted';
  static const String processing = 'Processing...';
  static const String pleaseWait = 'Please wait while we submit your request.';
  static const String depositCodeLabel = 'Deposit Code';
  static const String depositCodeHelp =
      'Use this code as the reference when you pay via 888STARZ.';
  static const String done = 'Done';
  static const String tryAgain = 'Try Again';
  static const String back = 'Back';

  // Orders
  static const String orders = 'Orders';
  static const String noOrders = 'No transactions yet';
  static const String orderDetails = 'Order Details';
  static const String method = 'Method';
  static const String transactionRef = 'Transaction Reference';
  static const String createdAt = 'Created';
  static const String completedAt = 'Completed';

  // Profile
  static const String profile = 'Profile';
  static const String name = 'Name';
}
