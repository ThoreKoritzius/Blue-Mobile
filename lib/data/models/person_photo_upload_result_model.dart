class PersonPhotoUploadResultModel {
  const PersonPhotoUploadResultModel({
    required this.photoPath,
    required this.status,
    required this.message,
    required this.recognitionUsed,
    required this.referenceFaceId,
    required this.autoAssignedCount,
    required this.error,
  });

  final String photoPath;
  final String status;
  final String message;
  final bool recognitionUsed;
  final int? referenceFaceId;
  final int autoAssignedCount;
  final String? error;

  factory PersonPhotoUploadResultModel.fromJson(Map<String, dynamic> json) {
    final faceIdValue = json['reference_face_id'];
    return PersonPhotoUploadResultModel(
      photoPath: (json['photo_path'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      message: (json['message'] ?? '').toString(),
      recognitionUsed: json['recognition_used'] == true,
      referenceFaceId: faceIdValue == null
          ? null
          : int.tryParse(faceIdValue.toString()),
      autoAssignedCount:
          int.tryParse((json['auto_assigned_count'] ?? '').toString()) ?? 0,
      error: (json['error'] ?? '').toString().isEmpty
          ? null
          : (json['error'] ?? '').toString(),
    );
  }
}
