import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'api/customer_api.dart';
import 'config.dart';
import 'screens/splash_screen.dart';
import 'state/auth_provider.dart';
import 'state/orders_provider.dart';
import 'state/wallet_provider.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BadalExchangeApp());
}

class BadalExchangeApp extends StatelessWidget {
  const BadalExchangeApp({super.key});

  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>(
          create: (_) => ApiClient(baseUrl: AppConfig.apiBaseUrl),
        ),
        ProxyProvider<ApiClient, CustomerApi>(
          update: (_, apiClient, __) => CustomerApi(apiClient),
        ),
        ChangeNotifierProxyProvider<CustomerApi, AuthProvider>(
          create: (context) => AuthProvider(
            apiClient: context.read<ApiClient>(),
            customerApi: context.read<CustomerApi>(),
            navigatorKey: navigatorKey,
          )..bootstrap(),
          update: (_, __, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<CustomerApi, WalletProvider>(
          create: (context) => WalletProvider(customerApi: context.read<CustomerApi>()),
          update: (_, __, previous) => previous!,
        ),
        ChangeNotifierProxyProvider<CustomerApi, OrdersProvider>(
          create: (context) => OrdersProvider(customerApi: context.read<CustomerApi>()),
          update: (_, __, previous) => previous!,
        ),
      ],
      child: MaterialApp(
        title: 'Badal Exchange',
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        theme: AppTheme.light,
        home: const SplashScreen(),
      ),
    );
  }
}
