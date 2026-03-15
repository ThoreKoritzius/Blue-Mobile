import 'package:flutter/material.dart';
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
    final session = auth.valueOrNull;
    final initialLoading = auth.isLoading && session == null && !auth.hasError;

    return MaterialApp(
      title: 'Blue Mobile',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
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
