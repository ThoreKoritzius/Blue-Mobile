class PersonRecognitionStatusModel {
  const PersonRecognitionStatusModel({
    required this.personId,
    required this.linkedFaceCount,
    required this.referenceFaceCount,
    required this.linkedImageCount,
    required this.candidateImageCount,
    required this.hasEmbedding,
    required this.profilePhotoPath,
    required this.profilePhotoIndexed,
    required this.profilePhotoFaceCount,
    required this.profilePhotoStatus,
    required this.profilePhotoMessage,
    required this.profilePhotoError,
    required this.referenceFaceId,
  });

  final int personId;
  final int linkedFaceCount;
  final int referenceFaceCount;
  final int linkedImageCount;
  final int candidateImageCount;
  final bool hasEmbedding;
  final String profilePhotoPath;
  final bool profilePhotoIndexed;
  final int profilePhotoFaceCount;
  final String profilePhotoStatus;
  final String profilePhotoMessage;
  final String? profilePhotoError;
  final int? referenceFaceId;

  bool get recognitionActive => hasEmbedding && referenceFaceCount > 0;

  factory PersonRecognitionStatusModel.empty({int personId = 0}) {
    return PersonRecognitionStatusModel(
      personId: personId,
      linkedFaceCount: 0,
      referenceFaceCount: 0,
      linkedImageCount: 0,
      candidateImageCount: 0,
      hasEmbedding: false,
      profilePhotoPath: '',
      profilePhotoIndexed: false,
      profilePhotoFaceCount: 0,
      profilePhotoStatus: 'missing',
      profilePhotoMessage: 'No profile photo uploaded.',
      profilePhotoError: null,
      referenceFaceId: null,
    );
  }

  factory PersonRecognitionStatusModel.fromJson(Map<String, dynamic> json) {
    int parseInt(Object? value) => int.tryParse((value ?? '').toString()) ?? 0;

    final faceIdValue = json['reference_face_id'];
    final referenceFaceId = faceIdValue == null
        ? null
        : int.tryParse(faceIdValue.toString());

    return PersonRecognitionStatusModel(
      personId: parseInt(json['person_id']),
      linkedFaceCount: parseInt(json['linked_face_count']),
      referenceFaceCount: parseInt(json['reference_face_count']),
      linkedImageCount: parseInt(json['linked_image_count']),
      candidateImageCount: parseInt(json['candidate_image_count']),
      hasEmbedding: json['has_embedding'] == true,
      profilePhotoPath: (json['profile_photo_path'] ?? '').toString(),
      profilePhotoIndexed: json['profile_photo_indexed'] == true,
      profilePhotoFaceCount: parseInt(json['profile_photo_face_count']),
      profilePhotoStatus: (json['profile_photo_status'] ?? '').toString(),
      profilePhotoMessage: (json['profile_photo_message'] ?? '').toString(),
      profilePhotoError: (json['profile_photo_error'] ?? '').toString().isEmpty
          ? null
          : (json['profile_photo_error'] ?? '').toString(),
      referenceFaceId: referenceFaceId,
    );
  }
}
