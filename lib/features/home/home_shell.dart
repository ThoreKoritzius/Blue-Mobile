import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../calendar/calendar_page.dart';
import '../chat/chat_page.dart';
import '../day/day_page.dart';
import '../map/map_page.dart';
import '../runs/runs_page.dart';
import '../search/search_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      try {
        await Future.wait([
          ref.read(storiesRepositoryProvider).warmRecentCache(limit: 3650),
          ref.read(runsRepositoryProvider).warmRecentCache(limitDays: 3650),
          ref.read(personRepositoryProvider).popular(first: 24),
        ]);
      } catch (_) {
        // Startup cache warming should not block the shell.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final tabIndex = ref.watch(selectedTabProvider);
    final dayAccent = ref.watch(dayAppBarAccentProvider);
    final dayDraft = ref.watch(dayDraftControllerProvider);
    final appBarBase = tabIndex == 0
        ? _complementaryScaffoldColor(dayAccent)
        : Theme.of(context).appBarTheme.backgroundColor ??
              Theme.of(context).colorScheme.surface;
    final appBarForeground =
        ThemeData.estimateBrightnessForColor(appBarBase) == Brightness.dark
        ? Colors.white
        : const Color(0xFF132238);
    final appBarGradient = tabIndex == 0
        ? [
            Color.lerp(appBarBase, dayAccent, 0.28) ?? appBarBase,
            Color.lerp(dayAccent, Colors.black, 0.18) ?? dayAccent,
          ]
        : [appBarBase, appBarBase];

    final pages = const [
      DayPage(),
      CalendarPage(),
      RunsPage(),
      ChatPage(),
      MapPage(),
    ];

    final labels = const ['Day', 'Calendar', 'Runs', 'Chat', 'Map'];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: appBarBase,
        foregroundColor: appBarForeground,
        elevation: 0,
        scrolledUnderElevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        flexibleSpace: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: appBarGradient,
            ),
          ),
        ),
        title: Text(labels[tabIndex]),
        actions: [
          IconButton(
            tooltip: 'Search memories',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SearchPage()),
              );
            },
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => _showSettingsSheet(context, ref),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Logout',
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: IndexedStack(index: tabIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        onDestinationSelected: (index) {
          if (index == tabIndex) return;
          if (tabIndex == 0 && !dayDraft.canNavigate) {
            final message = dayDraft.hasError
                ? (dayDraft.errorMessage ?? 'Retry needed before leaving Day.')
                : 'Finish saving before leaving Day.';
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
            return;
          }
          ref.read(selectedTabProvider.notifier).state = index;
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.book_outlined),
            selectedIcon: Icon(Icons.book),
            label: 'Day',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Calendar',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_run_outlined),
            selectedIcon: Icon(Icons.directions_run),
            label: 'Runs',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
        ],
      ),
    );
  }

  Color _complementaryScaffoldColor(Color source) {
    final hsl = HSLColor.fromColor(source);
    final rotated = hsl
        .withHue((hsl.hue + 180) % 360)
        .withSaturation((hsl.saturation * 0.72).clamp(0.24, 0.68))
        .withLightness(0.42);
    final softened = rotated.toColor();
    return Color.lerp(softened, source, 0.18) ?? softened;
  }

  void _showSettingsSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final themeMode = ref.watch(themeModeProvider);
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Settings',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Appearance',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.dark,
                          icon: Icon(Icons.dark_mode_outlined),
                          label: Text('Dark'),
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.light,
                          icon: Icon(Icons.light_mode_outlined),
                          label: Text('Light'),
                        ),
                      ],
                      selected: {themeMode},
                      onSelectionChanged: (selection) {
                        final mode = selection.first;
                        ref.read(themeModeProvider.notifier).setThemeMode(mode);
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Dark mode is the default for new installs.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
