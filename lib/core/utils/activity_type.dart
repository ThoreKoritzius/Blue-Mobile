import 'package:flutter/material.dart';

IconData activityIcon(String type) {
  switch (type) {
    case 'Run':
    case 'VirtualRun':
    case 'TrailRun':
      return Icons.directions_run_rounded;
    case 'Ride':
    case 'VirtualRide':
    case 'GravelRide':
    case 'MountainBikeRide':
    case 'EBikeRide':
    case 'EMountainBikeRide':
    case 'Velomobile':
    case 'Handcycle':
      return Icons.directions_bike_rounded;
    case 'Swim':
      return Icons.pool_rounded;
    case 'Walk':
      return Icons.directions_walk_rounded;
    case 'Hike':
      return Icons.hiking_rounded;
    case 'AlpineSki':
    case 'BackcountrySki':
    case 'NordicSki':
    case 'Snowboard':
      return Icons.downhill_skiing_rounded;
    case 'IceSkate':
    case 'InlineSkate':
    case 'RollerSki':
      return Icons.ice_skating_rounded;
    case 'WeightTraining':
    case 'Crossfit':
    case 'Workout':
    case 'Elliptical':
    case 'StairStepper':
      return Icons.fitness_center_rounded;
    case 'Yoga':
    case 'Pilates':
      return Icons.self_improvement_rounded;
    case 'Rowing':
    case 'Kayaking':
    case 'Canoeing':
    case 'StandUpPaddling':
    case 'Surfing':
    case 'Kitesurf':
    case 'Windsurf':
    case 'Sail':
      return Icons.rowing_rounded;
    case 'Golf':
      return Icons.golf_course_rounded;
    case 'Skateboard':
      return Icons.skateboarding_rounded;
    case 'RockClimbing':
    case 'Badminton':
    case 'Tennis':
    case 'Pickleball':
    case 'Squash':
    case 'TableTennis':
    case 'Soccer':
    case 'Football':
    case 'Rugby':
    case 'Basketball':
    case 'Racquetball':
    case 'Handball':
    case 'HighIntensityIntervalTraining':
      return Icons.sports_rounded;
    case 'Snowshoe':
      return Icons.ac_unit_rounded;
    case 'Wheelchair':
      return Icons.accessible_rounded;
    default:
      return Icons.directions_run_rounded;
  }
}

Color activityColor(String type) {
  switch (type) {
    case 'Run':
    case 'VirtualRun':
    case 'TrailRun':
      return const Color(0xFFE8733A);
    case 'Ride':
    case 'VirtualRide':
    case 'GravelRide':
    case 'MountainBikeRide':
    case 'EBikeRide':
    case 'EMountainBikeRide':
    case 'Velomobile':
    case 'Handcycle':
      return const Color(0xFF3A8FE8);
    case 'Swim':
      return const Color(0xFF2CB5C9);
    case 'Walk':
    case 'Hike':
      return const Color(0xFF5DAE5D);
    case 'AlpineSki':
    case 'BackcountrySki':
    case 'NordicSki':
    case 'Snowboard':
    case 'Snowshoe':
    case 'IceSkate':
      return const Color(0xFF6BAFCF);
    case 'WeightTraining':
    case 'Crossfit':
    case 'Workout':
    case 'Elliptical':
    case 'StairStepper':
    case 'HighIntensityIntervalTraining':
      return const Color(0xFFAA5DC9);
    case 'Yoga':
    case 'Pilates':
      return const Color(0xFFC97BAA);
    case 'Rowing':
    case 'Kayaking':
    case 'Canoeing':
    case 'StandUpPaddling':
    case 'Surfing':
    case 'Kitesurf':
    case 'Windsurf':
    case 'Sail':
      return const Color(0xFF3A7FD5);
    default:
      return const Color(0xFFE8733A);
  }
}

String activityFormatStartTime(String startTime) {
  final parts = startTime.split(':');
  if (parts.length >= 2) return '${parts[0]}:${parts[1]}';
  return startTime;
}

bool activityHasDistance(String type) {
  const noDistance = {
    'WeightTraining', 'Crossfit', 'Workout', 'Elliptical', 'StairStepper',
    'HighIntensityIntervalTraining', 'Yoga', 'Pilates', 'RockClimbing',
    'Badminton', 'Tennis', 'Pickleball', 'Squash', 'TableTennis',
    'Soccer', 'Football', 'Rugby', 'Basketball', 'Racquetball', 'Handball',
  };
  return !noDistance.contains(type);
}

String activityLabel(String type) {
  switch (type) {
    case 'Run': return 'Run';
    case 'VirtualRun': return 'Virtual Run';
    case 'TrailRun': return 'Trail Run';
    case 'Ride': return 'Ride';
    case 'VirtualRide': return 'Virtual Ride';
    case 'GravelRide': return 'Gravel Ride';
    case 'MountainBikeRide': return 'MTB Ride';
    case 'EBikeRide': return 'E-Bike Ride';
    case 'Swim': return 'Swim';
    case 'Walk': return 'Walk';
    case 'Hike': return 'Hike';
    case 'AlpineSki': return 'Ski';
    case 'BackcountrySki': return 'Backcountry Ski';
    case 'NordicSki': return 'Nordic Ski';
    case 'Snowboard': return 'Snowboard';
    case 'WeightTraining': return 'Weight Training';
    case 'Crossfit': return 'Crossfit';
    case 'Workout': return 'Workout';
    case 'Yoga': return 'Yoga';
    case 'Pilates': return 'Pilates';
    case 'Rowing': return 'Row';
    case 'Kayaking': return 'Kayak';
    case 'Golf': return 'Golf';
    case 'Skateboard': return 'Skateboard';
    case 'RockClimbing': return 'Climb';
    case 'Snowshoe': return 'Snowshoe';
    case 'IceSkate': return 'Ice Skate';
    case 'InlineSkate': return 'Inline Skate';
    case 'HighIntensityIntervalTraining': return 'HIIT';
    default: return type.isEmpty ? 'Activity' : type;
  }
}
