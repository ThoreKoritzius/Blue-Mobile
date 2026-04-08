import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../data/models/chat_widget_model.dart';

/// Default palette for chart series when no color is specified.
const _defaultSeriesColors = [
  Color(0xFF4CAF50),
  Color(0xFF2196F3),
  Color(0xFFFF9800),
  Color(0xFFE91E63),
  Color(0xFF9C27B0),
  Color(0xFF00BCD4),
  Color(0xFFFF5722),
  Color(0xFF8BC34A),
];

class ChatInlineChart extends StatelessWidget {
  const ChatInlineChart({super.key, required this.spec});

  final ChatChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            spec.title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Container(
          height: 260,
          padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: _buildChart(context),
        ),
      ],
    );
  }

  Widget _buildChart(BuildContext context) {
    switch (spec.type) {
      case 'bar':
        return _buildBarChart(context);
      case 'line':
      case 'area':
        return _buildLineChart(context, filled: spec.type == 'area');
      case 'pie':
        return _buildPieChart(context);
      default:
        return _buildBarChart(context);
    }
  }

  // ---------------------------------------------------------------------------
  // Bar chart
  // ---------------------------------------------------------------------------

  Widget _buildBarChart(BuildContext context) {
    final theme = Theme.of(context);
    if (spec.series.isEmpty) return const SizedBox.shrink();

    final firstSeries = spec.series.first;
    final data = firstSeries.data;
    if (data.isEmpty) return const SizedBox.shrink();

    final maxY = data.map((p) => p.y).reduce(math.max);
    final seriesColors = _resolveColors(spec.series);

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY * 1.15,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final label = data[groupIndex].x.toString();
              return BarTooltipItem(
                '$label\n${rod.toY.toStringAsFixed(1)}',
                TextStyle(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            axisNameWidget: spec.xLabel != null
                ? Text(spec.xLabel!, style: theme.textTheme.bodySmall)
                : null,
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: data.length > 12 ? 44 : 32,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (value != idx.toDouble()) return const SizedBox.shrink();
                if (idx < 0 || idx >= data.length) return const SizedBox.shrink();
                // Skip some labels if too many bars
                if (data.length > 16 && idx % 2 != 0) return const SizedBox.shrink();
                final label = _abbreviateLabel(data[idx].x.toString());
                final child = Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
                if (data.length > 12) {
                  return SideTitleWidget(
                    meta: meta,
                    child: RotatedBox(quarterTurns: -1, child: child),
                  );
                }
                return SideTitleWidget(meta: meta, child: child);
              },
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: spec.yLabel != null
                ? Text(spec.yLabel!, style: theme.textTheme.bodySmall)
                : null,
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) {
                if (value != meta.appliedInterval * (value / meta.appliedInterval).roundToDouble()) {
                  return const SizedBox.shrink();
                }
                return Text(
                  _formatNumber(value),
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY > 0 ? maxY / 4 : 1,
          getDrawingHorizontalLine: (value) => FlLine(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (var i = 0; i < data.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                for (var si = 0; si < spec.series.length; si++)
                  BarChartRodData(
                    toY: si < spec.series.length && i < spec.series[si].data.length
                        ? spec.series[si].data[i].y
                        : 0,
                    color: seriesColors[si],
                    width: data.length > 20 ? 6 : (spec.series.length == 1 ? 16 : 10),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Line / area chart
  // ---------------------------------------------------------------------------

  Widget _buildLineChart(BuildContext context, {bool filled = false}) {
    final theme = Theme.of(context);
    if (spec.series.isEmpty) return const SizedBox.shrink();

    final seriesColors = _resolveColors(spec.series);
    final allYValues = spec.series.expand((s) => s.data.map((p) => p.y));
    if (allYValues.isEmpty) return const SizedBox.shrink();
    final maxY = allYValues.reduce(math.max);
    final minY = allYValues.reduce(math.min);

    // Use x index for positioning
    final maxXCount = spec.series.map((s) => s.data.length).reduce(math.max);

    return LineChart(
      LineChartData(
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) {
              return spots.map((spot) {
                final si = spot.barIndex;
                final series = spec.series[si];
                final idx = spot.x.toInt();
                final label = idx < series.data.length ? series.data[idx].x.toString() : '';
                return LineTooltipItem(
                  '$label: ${spot.y.toStringAsFixed(1)}',
                  TextStyle(
                    color: seriesColors[si],
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                );
              }).toList();
            },
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            axisNameWidget: spec.xLabel != null
                ? Text(spec.xLabel!, style: theme.textTheme.bodySmall)
                : null,
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: maxXCount > 12 ? 44 : 32,
              interval: maxXCount > 12 ? (maxXCount / 6).ceilToDouble() : 1,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (value != idx.toDouble()) return const SizedBox.shrink();
                if (idx < 0 || idx >= spec.series.first.data.length) {
                  return const SizedBox.shrink();
                }
                final label = _abbreviateLabel(spec.series.first.data[idx].x.toString());
                final child = Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
                if (maxXCount > 12) {
                  return SideTitleWidget(
                    meta: meta,
                    child: RotatedBox(quarterTurns: -1, child: child),
                  );
                }
                return SideTitleWidget(meta: meta, child: child);
              },
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: spec.yLabel != null
                ? Text(spec.yLabel!, style: theme.textTheme.bodySmall)
                : null,
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) {
                return Text(
                  _formatNumber(value),
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY > minY ? (maxY - minY) / 4 : 1,
          getDrawingHorizontalLine: (value) => FlLine(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        minY: minY > 0 ? 0 : minY * 1.1,
        maxY: maxY * 1.15,
        lineBarsData: [
          for (var si = 0; si < spec.series.length; si++)
            LineChartBarData(
              spots: [
                for (var i = 0; i < spec.series[si].data.length; i++)
                  FlSpot(i.toDouble(), spec.series[si].data[i].y),
              ],
              isCurved: true,
              preventCurveOverShooting: true,
              color: seriesColors[si],
              barWidth: 3,
              dotData: FlDotData(
                show: spec.series[si].data.length <= 20,
              ),
              belowBarData: filled
                  ? BarAreaData(
                      show: true,
                      color: seriesColors[si].withValues(alpha: 0.15),
                    )
                  : BarAreaData(show: false),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pie chart
  // ---------------------------------------------------------------------------

  Widget _buildPieChart(BuildContext context) {
    final theme = Theme.of(context);
    if (spec.series.isEmpty || spec.series.first.data.isEmpty) {
      return const SizedBox.shrink();
    }

    final data = spec.series.first.data;
    final total = data.map((p) => p.y).fold(0.0, (a, b) => a + b);

    return PieChart(
      PieChartData(
        sectionsSpace: 2,
        centerSpaceRadius: 40,
        sections: [
          for (var i = 0; i < data.length; i++)
            PieChartSectionData(
              value: data[i].y,
              title: '${(data[i].y / total * 100).toStringAsFixed(0)}%',
              titleStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
              color: _defaultSeriesColors[i % _defaultSeriesColors.length],
              radius: 60,
              badgeWidget: Text(
                _abbreviateLabel(data[i].x.toString()),
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
              ),
              badgePositionPercentageOffset: 1.4,
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  List<Color> _resolveColors(List<ChatChartSeries> series) {
    return [
      for (var i = 0; i < series.length; i++)
        series[i].color ?? _defaultSeriesColors[i % _defaultSeriesColors.length],
    ];
  }

  static String _abbreviateLabel(String label) {
    if (label.length <= 5) return label;
    // YYYY-MM → Jan, Feb, … or just MM part
    final ymd = RegExp(r'^(\d{4})-(\d{2})(?:-(\d{2}))?$').firstMatch(label);
    if (ymd != null) {
      final month = int.tryParse(ymd.group(2)!) ?? 0;
      const months = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      final abbr = month >= 1 && month <= 12 ? months[month] : ymd.group(2)!;
      if (ymd.group(3) != null) return '$abbr ${ymd.group(3)}'; // Jan 15
      return abbr; // Jan
    }
    // Generic: keep up to 6 chars
    return label.length <= 6 ? label : '${label.substring(0, 5)}…';
  }

  static String _formatNumber(double value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toStringAsFixed(1);
  }
}
