import 'calendar_event_model.dart';
import 'daily_activity_model.dart';
import 'daily_weather_model.dart';
import 'person_model.dart';
import 'run_model.dart';
import 'story_day_model.dart';

enum MemorySearchResultType {
  story,
  run,
  file,
  timeline,
  calendar,
  weather,
  activity,
  person;

  String get graphqlName => switch (this) {
    MemorySearchResultType.story => 'STORY',
    MemorySearchResultType.run => 'RUN',
    MemorySearchResultType.file => 'FILE',
    MemorySearchResultType.timeline => 'TIMELINE',
    MemorySearchResultType.calendar => 'CALENDAR',
    MemorySearchResultType.weather => 'WEATHER',
    MemorySearchResultType.activity => 'ACTIVITY',
    MemorySearchResultType.person => 'PERSON',
  };

  String get label => switch (this) {
    MemorySearchResultType.story => 'Day',
    MemorySearchResultType.run => 'Run',
    MemorySearchResultType.file => 'Image',
    MemorySearchResultType.timeline => 'Timeline',
    MemorySearchResultType.calendar => 'Calendar',
    MemorySearchResultType.weather => 'Weather',
    MemorySearchResultType.activity => 'Activity',
    MemorySearchResultType.person => 'Person',
  };

  factory MemorySearchResultType.fromJson(Object? value) {
    return switch ((value ?? '').toString().toUpperCase()) {
      'RUN' => MemorySearchResultType.run,
      'FILE' => MemorySearchResultType.file,
      'TIMELINE' => MemorySearchResultType.timeline,
      'CALENDAR' => MemorySearchResultType.calendar,
      'WEATHER' => MemorySearchResultType.weather,
      'ACTIVITY' => MemorySearchResultType.activity,
      'PERSON' => MemorySearchResultType.person,
      _ => MemorySearchResultType.story,
    };
  }
}

enum MemorySearchMatchKind {
  text,
  keyword,
  semantic,
  date,
  location,
  person,
  contextDay,
  contextLocation;

  String get label => switch (this) {
    MemorySearchMatchKind.text => 'Text',
    MemorySearchMatchKind.keyword => 'Keyword',
    MemorySearchMatchKind.semantic => 'Related',
    MemorySearchMatchKind.date => 'Date',
    MemorySearchMatchKind.location => 'Location',
    MemorySearchMatchKind.person => 'Person',
    MemorySearchMatchKind.contextDay => 'Same day',
    MemorySearchMatchKind.contextLocation => 'Nearby',
  };

  factory MemorySearchMatchKind.fromJson(Object? value) {
    return switch ((value ?? '').toString().toUpperCase()) {
      'KEYWORD' => MemorySearchMatchKind.keyword,
      'SEMANTIC' => MemorySearchMatchKind.semantic,
      'DATE' => MemorySearchMatchKind.date,
      'LOCATION' => MemorySearchMatchKind.location,
      'PERSON' => MemorySearchMatchKind.person,
      'CONTEXT_DAY' => MemorySearchMatchKind.contextDay,
      'CONTEXT_LOCATION' => MemorySearchMatchKind.contextLocation,
      _ => MemorySearchMatchKind.text,
    };
  }
}

class MemorySearchFileModel {
  const MemorySearchFileModel({
    required this.path,
    required this.date,
    required this.favorite,
    required this.imageTags,
    required this.type,
    required this.size,
    required this.gps,
  });

  final String path;
  final String date;
  final bool favorite;
  final String imageTags;
  final String type;
  final int size;
  final String gps;

  factory MemorySearchFileModel.fromJson(Map<String, dynamic> json) {
    return MemorySearchFileModel(
      path: (json['path'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      favorite: json['favorite'] == true,
      imageTags: (json['imageTags'] ?? json['image_tags'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      gps: (json['gps'] ?? '').toString(),
    );
  }
}

class MemorySearchTimelineModel {
  const MemorySearchTimelineModel({
    required this.id,
    required this.segmentType,
    required this.startTime,
    required this.endTime,
    required this.placeName,
    required this.placeAddress,
    required this.activityType,
    required this.distanceMeters,
  });

  final int id;
  final String segmentType;
  final String startTime;
  final String endTime;
  final String placeName;
  final String placeAddress;
  final String activityType;
  final double distanceMeters;

  factory MemorySearchTimelineModel.fromJson(Map<String, dynamic> json) {
    return MemorySearchTimelineModel(
      id: int.tryParse((json['id'] ?? '').toString()) ?? 0,
      segmentType: (json['segmentType'] ?? json['segment_type'] ?? '')
          .toString(),
      startTime: (json['startTime'] ?? json['start_time'] ?? '').toString(),
      endTime: (json['endTime'] ?? json['end_time'] ?? '').toString(),
      placeName: (json['placeName'] ?? json['place_name'] ?? '').toString(),
      placeAddress: (json['placeAddress'] ?? json['place_address'] ?? '')
          .toString(),
      activityType: (json['activityType'] ?? json['activity_type'] ?? '')
          .toString(),
      distanceMeters:
          (json['distanceMeters'] ?? json['distance_meters'] as num?)
              ?.toDouble() ??
          0,
    );
  }
}

class MemorySearchResultModel {
  const MemorySearchResultModel({
    required this.type,
    required this.id,
    required this.date,
    required this.title,
    required this.subtitle,
    required this.score,
    required this.matchKinds,
    required this.locationLabel,
    required this.personLabel,
    this.story,
    this.run,
    this.file,
    this.timeline,
    this.calendarEvent,
    this.weather,
    this.activity,
    this.personRecord,
  });

  final MemorySearchResultType type;
  final String id;
  final String date;
  final String title;
  final String subtitle;
  final double? score;
  final List<MemorySearchMatchKind> matchKinds;
  final String locationLabel;
  final String personLabel;
  final StoryDayModel? story;
  final RunModel? run;
  final MemorySearchFileModel? file;
  final MemorySearchTimelineModel? timeline;
  final CalendarEventModel? calendarEvent;
  final DailyWeatherModel? weather;
  final DailyActivityModel? activity;
  final PersonModel? personRecord;

  String get effectiveDate {
    if (date.isNotEmpty) {
      return date;
    }
    if (story != null && story!.date.isNotEmpty) {
      return story!.date;
    }
    if (run != null && run!.startDateLocal.isNotEmpty) {
      return run!.startDateLocal;
    }
    if (file != null && file!.date.isNotEmpty) {
      return file!.date;
    }
    if (weather != null && weather!.date.isNotEmpty) {
      return weather!.date;
    }
    return '';
  }

  String get displayTitle {
    if (title.trim().isNotEmpty) {
      return title.trim();
    }
    if (story != null && story!.place.trim().isNotEmpty) {
      return story!.place.trim();
    }
    if (run != null && run!.name.trim().isNotEmpty) {
      return run!.name.trim();
    }
    if (calendarEvent != null && calendarEvent!.summary.trim().isNotEmpty) {
      return calendarEvent!.summary.trim();
    }
    if (personRecord != null) return personRecord!.displayName;
    if (timeline != null && timeline!.placeName.trim().isNotEmpty) {
      return timeline!.placeName.trim();
    }
    return type.label;
  }

  String get displaySubtitle {
    if (subtitle.trim().isNotEmpty) {
      return subtitle.trim();
    }
    if (story != null && story!.description.trim().isNotEmpty) {
      return story!.description.trim();
    }
    if (locationLabel.trim().isNotEmpty) {
      return locationLabel.trim();
    }
    if (personLabel.trim().isNotEmpty) {
      return personLabel.trim();
    }
    if (calendarEvent != null && calendarEvent!.location.trim().isNotEmpty) {
      return calendarEvent!.location.trim();
    }
    return '';
  }

  String get previewImagePath {
    if (file != null && file!.path.trim().isNotEmpty) {
      return file!.path.trim();
    }
    if (story != null && story!.highlightImage.trim().isNotEmpty) {
      return story!.highlightImage.trim();
    }
    return '';
  }

  String get place {
    if (locationLabel.trim().isNotEmpty) {
      return locationLabel.trim();
    }
    if (story != null && story!.place.trim().isNotEmpty) {
      return story!.place.trim();
    }
    if (timeline != null && timeline!.placeName.trim().isNotEmpty) {
      return timeline!.placeName.trim();
    }
    if (calendarEvent != null && calendarEvent!.location.trim().isNotEmpty) {
      return calendarEvent!.location.trim();
    }
    if (weather != null && (weather!.locationLabel ?? '').trim().isNotEmpty) {
      return weather!.locationLabel!.trim();
    }
    return '';
  }

  List<String> get metaChips {
    final values = <String>[
      if (personLabel.trim().isNotEmpty) personLabel.trim(),
      if (story != null) ...story!.people.take(2),
      if (story != null) ...story!.tags.take(2),
      ...matchKinds.take(2).map((kind) => kind.label),
    ];
    return values.toSet().take(4).toList();
  }

  factory MemorySearchResultModel.storyOffline(StoryDayModel story) {
    return MemorySearchResultModel(
      type: MemorySearchResultType.story,
      id: story.date,
      date: story.date,
      title: story.place.trim().isNotEmpty ? story.place.trim() : story.date,
      subtitle: story.description.trim(),
      score: null,
      matchKinds: const [MemorySearchMatchKind.text],
      locationLabel: story.place,
      personLabel: '',
      story: story,
    );
  }

  factory MemorySearchResultModel.fromJson(Map<String, dynamic> json) {
    final type = MemorySearchResultType.fromJson(json['type']);
    final rawDate = (json['date'] ?? '').toString();
    final storyJson = json['story'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(json['story'] as Map<String, dynamic>)
        : null;
    return MemorySearchResultModel(
      type: type,
      id: (json['id'] ?? '').toString(),
      date: rawDate,
      title: (json['title'] ?? '').toString(),
      subtitle: (json['subtitle'] ?? '').toString(),
      score: (json['score'] as num?)?.toDouble(),
      matchKinds: (json['matchKinds'] as List<dynamic>? ?? const [])
          .map(MemorySearchMatchKind.fromJson)
          .toList(),
      locationLabel: (json['locationLabel'] ?? '').toString(),
      personLabel: (json['personLabel'] ?? '').toString(),
      story: storyJson == null
          ? null
          : StoryDayModel.fromJson(
              rawDate.isNotEmpty
                  ? rawDate
                  : (storyJson['date'] ?? '').toString(),
              storyJson,
            ),
      run: json['run'] is Map<String, dynamic>
          ? RunModel.fromJson(Map<String, dynamic>.from(json['run'] as Map))
          : null,
      file: json['file'] is Map<String, dynamic>
          ? MemorySearchFileModel.fromJson(
              Map<String, dynamic>.from(json['file'] as Map),
            )
          : null,
      timeline: json['timeline'] is Map<String, dynamic>
          ? MemorySearchTimelineModel.fromJson(
              Map<String, dynamic>.from(json['timeline'] as Map),
            )
          : null,
      calendarEvent: json['calendarEvent'] is Map<String, dynamic>
          ? CalendarEventModel.fromJson(
              Map<String, dynamic>.from(json['calendarEvent'] as Map),
            )
          : null,
      weather: json['weather'] is Map<String, dynamic>
          ? DailyWeatherModel.fromJson(
              Map<String, dynamic>.from(json['weather'] as Map),
            )
          : null,
      activity: json['activity'] is Map<String, dynamic>
          ? DailyActivityModel.fromJson(
              Map<String, dynamic>.from(json['activity'] as Map),
            )
          : null,
      personRecord: json['personRecord'] is Map<String, dynamic>
          ? PersonModel.fromJson(
              Map<String, dynamic>.from(json['personRecord'] as Map),
            )
          : null,
    );
  }
}
