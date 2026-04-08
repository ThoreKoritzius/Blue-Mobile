import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/breakpoints.dart';
import '../../core/utils/url_sync.dart';
import '../../providers.dart';
import '../calendar/calendar_page.dart';
import '../chat/chat_page.dart';
import '../day/day_page.dart';
import '../map/map_page.dart';
import '../runs/runs_page.dart';
import '../search/search_page.dart';
import '../settings/settings_page.dart';

class _NavItem {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

const _navItems = [
  _NavItem(
    icon: Icons.book_outlined,
    selectedIcon: Icons.book,
    label: 'Day',
  ),
  _NavItem(
    icon: Icons.calendar_month_outlined,
    selectedIcon: Icons.calendar_month,
    label: 'Calendar',
  ),
  _NavItem(
    icon: Icons.chat_bubble_outline,
    selectedIcon: Icons.chat_bubble,
    label: 'Chat',
  ),
  _NavItem(
    icon: Icons.map_outlined,
    selectedIcon: Icons.map,
    label: 'Map',
  ),
];

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
      } catch (_) {}
    });
  }

  static String _dateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void _onDestinationSelected(int index) {
    final tabIndex = ref.read(selectedTabProvider);
    if (index == tabIndex) return;
    final dayDraft = ref.read(dayDraftControllerProvider);
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
    if (index == 0) {
      UrlSync.updateUrl(0, _dateStr(ref.read(selectedDateProvider)));
    } else {
      UrlSync.updateUrl(index);
    }
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SearchPage()),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabIndex = ref.watch(selectedTabProvider);
    ref.watch(dayDraftControllerProvider);

    // Sync date changes to browser URL.
    ref.listen<DateTime>(selectedDateProvider, (prev, next) {
      if (prev == null) return;
      if (ref.read(selectedTabProvider) != 0) return;
      UrlSync.updateUrl(0, _dateStr(next));
    });

    final isWide = MediaQuery.sizeOf(context).width >= Breakpoints.compact;

    const pages = [DayPage(), CalendarPage(), ChatPage(), MapPage()];
    final body = IndexedStack(index: tabIndex, children: pages);

    final appBar = AppBar(
      title: Text(_navItems[tabIndex].label),
      actions: isWide
          ? null
          : [
              IconButton(
                tooltip: 'Search memories',
                onPressed: _openSearch,
                icon: const Icon(Icons.search_rounded),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
    );

    if (isWide) {
      return Scaffold(
        appBar: appBar,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: tabIndex,
              onDestinationSelected: _onDestinationSelected,
              labelType: NavigationRailLabelType.all,
              leading: Column(
                children: [
                  IconButton(
                    tooltip: 'Search memories',
                    onPressed: _openSearch,
                    icon: const Icon(Icons.search_rounded),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: IconButton(
                      tooltip: 'Settings',
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ),
                ),
              ),
              destinations: [
                for (final item in _navItems)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.selectedIcon),
                    label: Text(item.label),
                  ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: [
          for (final item in _navItems)
            NavigationDestination(
              icon: Icon(item.icon),
              selectedIcon: Icon(item.selectedIcon),
              label: item.label,
            ),
        ],
      ),
    );
  }
}
