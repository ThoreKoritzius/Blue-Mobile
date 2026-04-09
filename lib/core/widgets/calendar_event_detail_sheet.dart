import 'package:flutter/material.dart';

Future<void> showCalendarEventDetailSheet(
  BuildContext context, {
  required String summary,
  required String timeLabel,
  String location = '',
  String description = '',
  String sourceLabel = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF1F1F1F),
    builder: (context) {
      final theme = Theme.of(context);
      final colorScheme = theme.colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      summary.isEmpty ? 'Calendar event' : summary,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _CalendarDetailRow(
                icon: Icons.schedule_rounded,
                label: 'Time',
                value: timeLabel,
              ),
              if (location.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                _CalendarDetailRow(
                  icon: Icons.place_rounded,
                  label: 'Location',
                  value: location.trim(),
                ),
              ],
              if (sourceLabel.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                _CalendarDetailRow(
                  icon: Icons.storage_rounded,
                  label: 'Source',
                  value: sourceLabel.trim(),
                ),
              ],
              if (description.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Description',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description.trim(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    height: 1.45,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _CalendarDetailRow extends StatelessWidget {
  const _CalendarDetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.white54),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white54,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
