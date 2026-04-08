import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'features/auth/login_page.dart';
import 'features/home/home_shell.dart';
import 'providers.dart';

String todayDateStr() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/day/${todayDateStr()}',
    routes: [
      ShellRoute(
        builder: (context, state, child) => const HomeShell(),
        routes: [
          GoRoute(
            path: '/day/:date',
            pageBuilder: (context, state) {
              final dateStr = state.pathParameters['date'] ?? todayDateStr();
              final parsed = DateTime.tryParse(dateStr);
              if (parsed != null) {
                Future.microtask(() {
                  final current = ref.read(selectedDateProvider);
                  final normalized = DateUtils.dateOnly(parsed);
                  if (DateUtils.dateOnly(current) != normalized) {
                    ref.read(selectedDateProvider.notifier).state = normalized;
                  }
                });
              }
              Future.microtask(() {
                ref.read(selectedTabProvider.notifier).state = 0;
              });
              return const NoTransitionPage(child: SizedBox.shrink());
            },
          ),
          GoRoute(
            path: '/calendar',
            pageBuilder: (context, state) {
              Future.microtask(() {
                ref.read(selectedTabProvider.notifier).state = 1;
              });
              return const NoTransitionPage(child: SizedBox.shrink());
            },
          ),
          GoRoute(
            path: '/chat',
            pageBuilder: (context, state) {
              Future.microtask(() {
                ref.read(selectedTabProvider.notifier).state = 2;
              });
              return const NoTransitionPage(child: SizedBox.shrink());
            },
          ),
          GoRoute(
            path: '/map',
            pageBuilder: (context, state) {
              Future.microtask(() {
                ref.read(selectedTabProvider.notifier).state = 3;
              });
              return const NoTransitionPage(child: SizedBox.shrink());
            },
          ),
        ],
      ),
      GoRoute(
        path: '/',
        redirect: (_, __) => '/day/${todayDateStr()}',
      ),
    ],
  );
});

class BlueMobileApp extends ConsumerWidget {
  const BlueMobileApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final themeMode = ref.watch(themeModeProvider);
    final session = auth.valueOrNull;
    final initialLoading = auth.isLoading && session == null && !auth.hasError;
    ref.read(themeModeProvider.notifier).initialize();

    if (initialLoading) {
      return MaterialApp(
        title: 'Blue',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: Brightness.light),
        darkTheme: buildAppTheme(brightness: Brightness.dark),
        themeMode: themeMode,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    if (session == null) {
      return MaterialApp(
        title: 'Blue',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: Brightness.light),
        darkTheme: buildAppTheme(brightness: Brightness.dark),
        themeMode: themeMode,
        home: LoginPage(
          initialError: auth.hasError
              ? auth.error.toString().replaceFirst('Exception: ', '')
              : null,
        ),
      );
    }

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Blue',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
