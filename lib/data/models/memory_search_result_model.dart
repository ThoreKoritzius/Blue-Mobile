class MemorySearchResultModel {
  const MemorySearchResultModel({
    required this.date,
    required this.place,
    required this.names,
    required this.description,
    required this.keywords,
    required this.country,
    required this.highlightImage,
    required this.path,
  });

  final String date;
  final String place;
  final String names;
  final String description;
  final String keywords;
  final String country;
  final String highlightImage;
  final String path;

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

  String get previewImagePath {
    if (highlightImage.isNotEmpty) return highlightImage;
    return path;
  }

  factory MemorySearchResultModel.fromJson(Map<String, dynamic> json) {
    return MemorySearchResultModel(
      date: (json['date'] ?? '').toString(),
      place: (json['place'] ?? '').toString(),
      names: (json['names'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      keywords: (json['keywords'] ?? '').toString(),
      country: (json['country'] ?? '').toString(),
      highlightImage: (json['highlight_image'] ?? '').toString(),
      path: (json['path'] ?? '').toString(),
    );
  }
}
