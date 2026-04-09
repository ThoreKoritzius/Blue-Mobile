import 'calendar_event_model.dart';
import 'daily_activity_model.dart';
import 'daily_weather_model.dart';
import 'day_media_model.dart';
import 'run_model.dart';
import 'story_day_model.dart';

class DayPayloadModel {
  const DayPayloadModel({
    required this.story,
    required this.media,
    required this.runs,
    required this.events,
    required this.detailsLoaded,
    this.activity,
    this.weather,
  });

  final StoryDayModel story;
  final List<DayMediaModel> media;
  final List<RunModel> runs;
  final List<CalendarEventModel> events;
  final bool detailsLoaded;
  final DailyActivityModel? activity;
  final DailyWeatherModel? weather;

  DayPayloadModel copyWith({
    StoryDayModel? story,
    List<DayMediaModel>? media,
    List<RunModel>? runs,
    List<CalendarEventModel>? events,
    bool? detailsLoaded,
    DailyActivityModel? activity,
    DailyWeatherModel? weather,
  }) {
    return DayPayloadModel(
      story: story ?? this.story,
      media: media ?? this.media,
      runs: runs ?? this.runs,
      events: events ?? this.events,
      detailsLoaded: detailsLoaded ?? this.detailsLoaded,
      activity: activity ?? this.activity,
      weather: weather ?? this.weather,
    );
  }
}
