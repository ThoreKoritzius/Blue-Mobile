import 'person_model.dart';

class StoryDayModel {
  const StoryDayModel({
    required this.date,
    required this.place,
    required this.names,
    required this.personIds,
    required this.description,
    required this.food,
    required this.sport,
    required this.highlightImage,
    required this.keywords,
    required this.country,
  });

  final String date;
  final String place;
  final String names;
  final List<int> personIds;
  final String description;
  final String food;
  final String sport;
  final String highlightImage;
  final String keywords;
  final String country;

  List<String> get people => names
      .split(';')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();

  List<String> get tags => keywords
      .split(';')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();

  StoryDayModel copyWith({
    String? date,
    String? place,
    String? names,
    List<int>? personIds,
    String? description,
    String? food,
    String? sport,
    String? highlightImage,
    String? keywords,
    String? country,
  }) {
    return StoryDayModel(
      date: date ?? this.date,
      place: place ?? this.place,
      names: names ?? this.names,
      personIds: personIds ?? this.personIds,
      description: description ?? this.description,
      food: food ?? this.food,
      sport: sport ?? this.sport,
      highlightImage: highlightImage ?? this.highlightImage,
      keywords: keywords ?? this.keywords,
      country: country ?? this.country,
    );
  }

  Map<String, dynamic> toSaveInput() {
    return {
      'place': place,
      'personIds': personIds,
      'description': description,
      'highlightImage': highlightImage,
      'keywords': keywords,
      'country': country,
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'date': date,
      'place': place,
      'names': names,
      'person_ids': personIds,
      'description': description,
      'food': food,
      'sport': sport,
      'highlight_image': highlightImage,
      'keywords': keywords,
      'country': country,
    };
  }

  factory StoryDayModel.empty(String date) => StoryDayModel(
    date: date,
    place: '',
    names: '',
    personIds: const <int>[],
    description: '',
    food: '',
    sport: '',
    highlightImage: '',
    keywords: '',
    country: '',
  );

  factory StoryDayModel.fromJson(String date, Map<String, dynamic> json) {
    final rawPersons = json['persons'] as List<dynamic>? ?? const [];
    final persons = rawPersons
        .whereType<Map<String, dynamic>>()
        .map(PersonModel.fromJson)
        .toList();
    final personNames = persons
        .map((person) => person.displayName)
        .where((name) => name.trim().isNotEmpty)
        .toList();

    return StoryDayModel(
      date: date,
      place: (json['place'] ?? '').toString(),
      names: personNames.isNotEmpty
          ? personNames.join(';')
          : (json['names'] ?? '').toString(),
      personIds: persons
          .map((person) => person.id)
          .where((id) => id > 0)
          .toList(),
      description: (json['description'] ?? '').toString(),
      food: (json['food'] ?? '').toString(),
      sport: (json['sport'] ?? '').toString(),
      highlightImage: (json['highlightImage'] ?? json['highlight_image'] ?? '')
          .toString(),
      keywords: (json['keywords'] ?? '').toString(),
      country: (json['country'] ?? '').toString(),
    );
  }
}
