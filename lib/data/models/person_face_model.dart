class PersonFaceModel {
  const PersonFaceModel({
    required this.faceId,
    required this.path,
    required this.cropPath,
    required this.isReference,
  });

  final int faceId;
  final String path;
  final String cropPath;
  final bool isReference;

  factory PersonFaceModel.fromJson(Map<String, dynamic> json) {
    int parseId(Object? value) {
      if (value is int) return value;
      return int.tryParse((value ?? '').toString()) ?? 0;
    }

    return PersonFaceModel(
      faceId: parseId(json['face_id']),
      path: (json['path'] ?? '').toString(),
      cropPath: (json['crop_path'] ?? '').toString(),
      isReference: json['is_reference'] == true,
    );
  }
}
