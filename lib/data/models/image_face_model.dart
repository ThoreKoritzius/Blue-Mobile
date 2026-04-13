class ImageFaceModel {
  const ImageFaceModel({
    required this.faceId,
    required this.path,
    required this.cropPath,
    required this.personId,
    required this.personName,
    required this.isReference,
    required this.bbox,
    required this.score,
  });

  final int faceId;
  final String path;
  final String cropPath;
  final int? personId;
  final String personName;
  final bool isReference;
  final List<double> bbox;
  final double? score;

  bool get isLabeled => personId != null && personName.trim().isNotEmpty;

  factory ImageFaceModel.fromJson(Map<String, dynamic> json) {
    int parseInt(Object? value) {
      if (value is int) return value;
      return int.tryParse((value ?? '').toString()) ?? 0;
    }

    double? parseDouble(Object? value) {
      if (value is num) return value.toDouble();
      return double.tryParse((value ?? '').toString());
    }

    final rawBbox = json['bbox'];
    final bbox = rawBbox is List
        ? rawBbox
              .map((value) => parseDouble(value) ?? 0)
              .toList(growable: false)
        : const <double>[];
    final personIdValue = json['person_id'] ?? json['personId'];
    final parsedPersonId = personIdValue == null
        ? null
        : int.tryParse(personIdValue.toString());

    return ImageFaceModel(
      faceId: parseInt(json['face_id'] ?? json['faceId']),
      path: (json['path'] ?? '').toString(),
      cropPath: (json['crop_path'] ?? json['cropPath'] ?? '').toString(),
      personId: parsedPersonId,
      personName: (json['person_name'] ?? json['personName'] ?? '').toString(),
      isReference: json['is_reference'] == true || json['isReference'] == true,
      bbox: bbox,
      score: parseDouble(json['score']),
    );
  }
}
