import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/section_card.dart';
import '../../data/models/run_model.dart';
import '../../providers.dart';
import 'run_detail_page.dart';

class RunsPage extends ConsumerStatefulWidget {
  const RunsPage({super.key});

  @override
  ConsumerState<RunsPage> createState() => _RunsPageState();
}

class _RunsPageState extends ConsumerState<RunsPage> {
  List<RunModel> _runs = const [];
  List<RunModel> _monthly = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final runs = await ref.read(runsRepositoryProvider).listRuns();
      final monthly = await ref.read(runsRepositoryProvider).monthlyRuns();
      if (mounted) {
        setState(() {
          _runs = runs;
          _monthly = monthly;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showDetail(RunModel run) async {
    final repo = ref.read(runsRepositoryProvider);
    final bundle = await repo.loadDetailBundle(run.id);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RunDetailPage(
          run: run,
          summary: bundle.summary,
          detail: bundle.detail,
          headers: _authHeaders(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final totalKm = _runs.fold<double>(0, (sum, item) => sum + item.distanceKm);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionCard(
          title: 'Summary',
          child: Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              _MetricCard(label: 'Total runs', value: _runs.length.toString()),
              _MetricCard(label: 'Total km', value: totalKm.toStringAsFixed(1)),
              _MetricCard(
                label: 'Months tracked',
                value: _monthly.length.toString(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Runs',
          child: Column(
            children: _runs
                .map(
                  (run) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: isDark
                            ? [
                                colorScheme.surfaceContainerHighest,
                                colorScheme.surfaceContainer,
                              ]
                            : [
                                const Color(0xFFFFFFFF),
                                const Color(0xFFF4F8FF),
                              ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark
                              ? const Color(0x24000000)
                              : const Color(0x12000000),
                          blurRadius: 16,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      contentPadding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                      onTap: () => _showDetail(run),
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: isDark
                              ? colorScheme.primary.withValues(alpha: 0.18)
                              : const Color(0xFFE7F0FF),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.directions_run,
                          color: colorScheme.primary,
                        ),
                      ),
                      title: Text(
                        run.name.isEmpty ? 'Run ${run.id}' : run.name,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${run.startDateLocal} · ${run.distanceKm.toStringAsFixed(1)} km',
                        ),
                      ),
                      trailing: Container(
                        width: 84,
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isDark
                                ? [
                                    colorScheme.surfaceContainerHigh,
                                    colorScheme.surfaceContainerHighest,
                                  ]
                                : [
                                    const Color(0xFFEAF2FF),
                                    const Color(0xFFD8E7FF),
                                  ],
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.route_rounded,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  Map<String, String> _authHeaders() {
    final tokenStore = ref.read(authTokenStoreProvider);
    final token =
        ref.read(authControllerProvider).value?.accessToken ??
        tokenStore.peekToken();
    final gatewayToken = tokenStore.peekGatewayToken();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (gatewayToken != null && gatewayToken.isNotEmpty)
        'X-Gateway-Session': gatewayToken,
    };
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 110,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(label),
        ],
      ),
    );
  }
}
