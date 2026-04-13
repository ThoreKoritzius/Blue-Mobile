import 'image_face_model.dart';

class ImageFacesPayloadModel {
  const ImageFacesPayloadModel({
    required this.path,
    required this.status,
    required this.message,
    required this.failureReason,
    required this.faces,
  });

  final String path;
  final String status;
  final String message;
  final String? failureReason;
  final List<ImageFaceModel> faces;

  bool get hasFaces => faces.isNotEmpty;
  bool get isPending => status == 'pending';
  bool get isFailed => status == 'failed';
  bool get hasNoFaces => status == 'no_faces';

  factory ImageFacesPayloadModel.fromJson(Map<String, dynamic> json) {
    final rawFaces = json['faces'] as List<dynamic>? ?? const [];
    return ImageFacesPayloadModel(
      path: (json['path'] ?? '').toString(),
      status: (json['status'] ?? 'pending').toString(),
      message: (json['message'] ?? '').toString(),
      failureReason: (json['failure_reason'] ?? json['failureReason'])
              ?.toString()
              .trim()
              .isEmpty ==
          true
          ? null
          : (json['failure_reason'] ?? json['failureReason'])?.toString(),
      faces: rawFaces
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .map(ImageFaceModel.fromJson)
          .toList(),
    );
  }
}
