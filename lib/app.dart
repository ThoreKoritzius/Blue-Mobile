import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/auth/login_page.dart';
import 'features/home/home_shell.dart';
import 'providers.dart';

class BlueMobileApp extends ConsumerStatefulWidget {
  const BlueMobileApp({super.key});

  @override
  ConsumerState<BlueMobileApp> createState() => _BlueMobileAppState();
}

class _BlueMobileAppState extends ConsumerState<BlueMobileApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(authControllerProvider.notifier).restoreSession();
    }
  }

  @override
  Widget build(BuildContext context) {
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
