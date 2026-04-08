import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/auth/login_page.dart';
import 'features/home/home_shell.dart';
import 'providers.dart';

class BlueMobileApp extends ConsumerWidget {
  const BlueMobileApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final session = auth.valueOrNull;
    final initialLoading = auth.isLoading && session == null && !auth.hasError;
    ref.read(themeModeProvider.notifier).initialize();

    return MaterialApp(
      title: 'Blue',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [
        Locale('en', 'US'),
        Locale('en', 'GB'),
        Locale('de', 'DE'),
      ],
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: themeMode,
      home: initialLoading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (session != null
                ? const HomeShell()
                : LoginPage(
                    initialError: auth.hasError
                        ? auth.error.toString().replaceFirst('Exception: ', '')
                        : null,
                  )),
    );
  }
}
