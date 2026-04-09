import 'package:flutter/material.dart';

import '../../../data/models/daily_weather_model.dart';

class DayWeatherPresentation {
  const DayWeatherPresentation({
    required this.label,
    required this.icon,
    required this.iconColor,
  });

  final String label;
  final IconData icon;
  final Color iconColor;
}

DayWeatherPresentation resolveDayWeatherPresentation(
  BuildContext context,
  int? code,
) {
  final colorScheme = Theme.of(context).colorScheme;
  const sunnyColor = Color(0xFFF2B300);
  const rainColor = Color(0xFF1E88E5);
  const snowColor = Color(0xFF5C6BC0);
  const stormColor = Color(0xFF546E7A);
  final neutralColor = colorScheme.onPrimaryContainer;

  switch (code) {
    case 0:
      return const DayWeatherPresentation(
        label: 'Sunny',
        icon: Icons.wb_sunny_rounded,
        iconColor: sunnyColor,
      );
    case 1:
      return const DayWeatherPresentation(
        label: 'Sunny',
        icon: Icons.light_mode_rounded,
        iconColor: sunnyColor,
      );
    case 2:
      return DayWeatherPresentation(
        label: 'Partly cloudy',
        icon: Icons.cloud_queue_rounded,
        iconColor: neutralColor,
      );
    case 3:
      return DayWeatherPresentation(
        label: 'Overcast',
        icon: Icons.cloud_rounded,
        iconColor: neutralColor,
      );
    case 45:
      return DayWeatherPresentation(
        label: 'Fog',
        icon: Icons.blur_on_rounded,
        iconColor: neutralColor,
      );
    case 48:
      return DayWeatherPresentation(
        label: 'Freezing fog',
        icon: Icons.blur_on_rounded,
        iconColor: neutralColor,
      );
    case 51:
      return const DayWeatherPresentation(
        label: 'Light drizzle',
        icon: Icons.grain_rounded,
        iconColor: rainColor,
      );
    case 53:
      return const DayWeatherPresentation(
        label: 'Drizzle',
        icon: Icons.grain_rounded,
        iconColor: rainColor,
      );
    case 55:
      return const DayWeatherPresentation(
        label: 'Heavy drizzle',
        icon: Icons.grain_rounded,
        iconColor: rainColor,
      );
    case 56:
      return const DayWeatherPresentation(
        label: 'Light freezing drizzle',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 57:
      return const DayWeatherPresentation(
        label: 'Freezing drizzle',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 61:
      return const DayWeatherPresentation(
        label: 'Light rain',
        icon: Icons.umbrella_rounded,
        iconColor: rainColor,
      );
    case 63:
      return const DayWeatherPresentation(
        label: 'Rain',
        icon: Icons.umbrella_rounded,
        iconColor: rainColor,
      );
    case 65:
      return const DayWeatherPresentation(
        label: 'Heavy rain',
        icon: Icons.umbrella_rounded,
        iconColor: rainColor,
      );
    case 66:
      return const DayWeatherPresentation(
        label: 'Light freezing rain',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 67:
      return const DayWeatherPresentation(
        label: 'Freezing rain',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 71:
      return const DayWeatherPresentation(
        label: 'Light snow',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 73:
      return const DayWeatherPresentation(
        label: 'Snow',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 75:
      return const DayWeatherPresentation(
        label: 'Heavy snow',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 77:
      return const DayWeatherPresentation(
        label: 'Snow grains',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 80:
      return const DayWeatherPresentation(
        label: 'Light showers',
        icon: Icons.umbrella_rounded,
        iconColor: rainColor,
      );
    case 81:
      return const DayWeatherPresentation(
        label: 'Rain showers',
        icon: Icons.umbrella_rounded,
        iconColor: rainColor,
      );
    case 82:
      return const DayWeatherPresentation(
        label: 'Heavy showers',
        icon: Icons.umbrella_rounded,
        iconColor: rainColor,
      );
    case 85:
      return const DayWeatherPresentation(
        label: 'Light snow showers',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 86:
      return const DayWeatherPresentation(
        label: 'Snow showers',
        icon: Icons.ac_unit_rounded,
        iconColor: snowColor,
      );
    case 95:
      return const DayWeatherPresentation(
        label: 'Thunderstorm',
        icon: Icons.thunderstorm_rounded,
        iconColor: stormColor,
      );
    case 96:
      return const DayWeatherPresentation(
        label: 'Thunderstorm with hail',
        icon: Icons.thunderstorm_rounded,
        iconColor: stormColor,
      );
    case 99:
      return const DayWeatherPresentation(
        label: 'Severe storm with hail',
        icon: Icons.thunderstorm_rounded,
        iconColor: stormColor,
      );
    default:
      return DayWeatherPresentation(
        label: 'Weather summary',
        icon: Icons.cloud_queue_rounded,
        iconColor: neutralColor,
      );
  }
}

class DayWeatherSection extends StatelessWidget {
  const DayWeatherSection({
    super.key,
    required this.weather,
    this.onTap,
  });

  final DailyWeatherModel weather;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final presentation = resolveDayWeatherPresentation(
      context,
      weather.weatherCode,
    );
    final range = _temperatureRangeLabel(weather);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colorScheme.primaryContainer.withValues(alpha: 0.88),
                    colorScheme.secondaryContainer.withValues(alpha: 0.78),
                  ],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      presentation.icon,
                      color: presentation.iconColor,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          presentation.label,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          range,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.86,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colorScheme.onPrimaryContainer.withValues(
                        alpha: 0.82,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _temperatureRangeLabel(DailyWeatherModel weather) {
    final max = weather.temperatureMaxC;
    final min = weather.temperatureMinC;
    if (max == null && min == null) return 'No temperature range available';
    if (max != null && min != null) {
      return '${max.toStringAsFixed(0)}° / ${min.toStringAsFixed(0)}°';
    }
    if (max != null) return '${max.toStringAsFixed(0)}° high';
    return '${min!.toStringAsFixed(0)}° low';
  }
}
