import 'day_media_model.dart';

enum UploadItemStatus { queued, uploading, processing, done, failed }

class UploadItemStateModel {
  const UploadItemStateModel({
    required this.id,
    required this.fileName,
    required this.localPath,
    required this.progress,
    required this.status,
    this.errorMessage,
    this.media,
  });

  final String id;
  final String fileName;
  final String localPath;
  final double progress;
  final UploadItemStatus status;
  final String? errorMessage;
  final DayMediaModel? media;

  UploadItemStateModel copyWith({
    double? progress,
    UploadItemStatus? status,
    String? errorMessage,
    bool clearError = false,
    DayMediaModel? media,
  }) {
    return UploadItemStateModel(
      id: id,
      fileName: fileName,
      localPath: localPath,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      media: media ?? this.media,
    );
  }
}

class UploadBatchResultModel {
  const UploadBatchResultModel({
    required this.message,
    required this.media,
    required this.uploadCount,
    required this.autoAssignedHighlight,
    required this.highlightImage,
  });

  final String message;
  final List<DayMediaModel> media;
  final int uploadCount;
  final bool autoAssignedHighlight;
  final String highlightImage;

  factory UploadBatchResultModel.fromJson(Map<String, dynamic> json) {
    final files = json['files'] as List<dynamic>? ?? const [];
    return UploadBatchResultModel(
      message: (json['message'] ?? 'uploaded').toString(),
      media: files
          .whereType<Map<String, dynamic>>()
          .map(DayMediaModel.fromJson)
          .toList(),
      uploadCount: (json['uploadCount'] as num?)?.toInt() ?? files.length,
      autoAssignedHighlight: json['autoAssignedHighlight'] == true,
      highlightImage: (json['highlightImage'] ?? '').toString(),
    );
  }
}

class UploadBatchStateModel {
  const UploadBatchStateModel({
    required this.items,
    required this.overallProgress,
    required this.uploading,
    this.result,
    this.errorMessage,
  });

  final List<UploadItemStateModel> items;
  final double overallProgress;
  final bool uploading;
  final UploadBatchResultModel? result;
  final String? errorMessage;
}
