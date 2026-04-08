import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/breakpoints.dart';
import '../../data/models/auth_session.dart';
import '../../providers.dart';
import 'data_sources_page.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final session = ref.watch(authControllerProvider).valueOrNull;
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark;
    final screenWidth = MediaQuery.sizeOf(context).width;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Breakpoints.compact),
          child: ListView(
            padding: EdgeInsets.symmetric(
              horizontal: screenWidth > Breakpoints.compact ? 32 : 20,
              vertical: 20,
            ),
            children: [
              // ── Account ──
              _AccountTile(
                session: session,
                colorScheme: colorScheme,
                theme: theme,
                onSignOut: _confirmSignOut,
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.lock_outline_rounded,
                    color: colorScheme.primary,
                  ),
                  title: Text(
                    'Change Password',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showChangePasswordDialog,
                ),
              ),
              const SizedBox(height: 24),

              // ── Appearance ──
              Text(
                'Appearance',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isDark
                            ? Icons.dark_mode_rounded
                            : Icons.light_mode_rounded,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'Theme',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                        ],
                        selected: {themeMode},
                        onSelectionChanged: (selection) {
                          ref
                              .read(themeModeProvider.notifier)
                              .setThemeMode(selection.first);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── Data Import ──
              Text(
                'Data',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.storage_rounded,
                    color: colorScheme.primary,
                  ),
                  title: Text(
                    'Data Sources',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    'Timeline, Strava, Takeout and Calendar',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DataSourcesPage(),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showChangePasswordDialog() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        var loading = false;
        String? errorMessage;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Change Password'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: currentCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Current password',
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: newCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'New password',
                      ),
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Required';
                        if (v.length < 8) return 'At least 8 characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: confirmCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm new password',
                      ),
                      validator: (v) {
                        if (v != newCtrl.text) return 'Passwords do not match';
                        return null;
                      },
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: loading
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() {
                            loading = true;
                            errorMessage = null;
                          });
                          try {
                            await ref
                                .read(authRepositoryProvider)
                                .changePassword(currentCtrl.text, newCtrl.text);
                            if (context.mounted) {
                              Navigator.of(context).pop(true);
                            }
                          } catch (e) {
                            setDialogState(() {
                              loading = false;
                              errorMessage = e.toString().replaceFirst(
                                'Exception: ',
                                '',
                              );
                            });
                          }
                        },
                  child: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Change'),
                ),
              ],
            );
          },
        );
      },
    );

    currentCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();

    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed successfully')),
      );
    }
  }

  Future<void> _confirmSignOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Sign out?'),
          content: const Text(
            'This removes the current session from this device and returns you to the login screen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );

    if (shouldSignOut != true || !mounted) return;
    await ref.read(authControllerProvider.notifier).signOut();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.session,
    required this.colorScheme,
    required this.theme,
    required this.onSignOut,
  });

  final AuthSession? session;
  final ColorScheme colorScheme;
  final ThemeData theme;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final username = session?.username.trim();
    final hasUser = username != null && username.isNotEmpty;
    final initial = hasUser ? username[0].toUpperCase() : '?';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colorScheme.primaryContainer,
              foregroundColor: colorScheme.onPrimaryContainer,
              child: Text(
                initial,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasUser ? username : 'Blue',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Your personal diary',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Sign out',
              onPressed: onSignOut,
              icon: Icon(
                Icons.logout_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
