class StoryDayModel {
  const StoryDayModel({
    required this.date,
    required this.place,
    required this.names,
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
      'names': names,
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
    description: '',
    food: '',
    sport: '',
    highlightImage: '',
    keywords: '',
    country: '',
  );

  factory StoryDayModel.fromJson(String date, Map<String, dynamic> json) {
    return StoryDayModel(
      date: date,
      place: (json['place'] ?? '').toString(),
      names: (json['names'] ?? '').toString(),
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
