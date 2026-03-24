import 'dart:async';
import 'dart:io';

import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/day_media_model.dart';
import '../models/upload_batch_state_model.dart';

abstract class FilesRepository {
  Future<List<DayMediaModel>> getDayFiles(String day, {int first = 300});
  Future<List<DayMediaModel>> listFiles({int first = 2000});
  Stream<UploadBatchStateModel> uploadFilesWithProgress(
    String day,
    List<File> files,
  );
  Future<void> updateHighlight(String imagePath);
}

class GraphqlFilesRepository implements FilesRepository {
  GraphqlFilesRepository(this._gql);

  final GraphqlService _gql;

  @override
  Future<List<DayMediaModel>> getDayFiles(String day, {int first = 300}) async {
    final response = await _gql.query(
      GqlDocuments.filesDay,
      variables: {'day': day, 'first': first},
    );
    final edges =
        (((response['files'] as Map<String, dynamic>)['day']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);

    return edges
        .map((item) => (item as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map(DayMediaModel.fromJson)
        .toList();
  }

  @override
  Future<List<DayMediaModel>> listFiles({int first = 2000}) async {
    final response = await _gql.query(
      GqlDocuments.filesList,
      variables: {'first': first},
    );
    final edges =
        (((response['files'] as Map<String, dynamic>)['list']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);

    return edges
        .map((item) => (item as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map(DayMediaModel.fromJson)
        .toList();
  }

  @override
  Stream<UploadBatchStateModel> uploadFilesWithProgress(
    String day,
    List<File> files,
  ) {
    final controller = StreamController<UploadBatchStateModel>();

    Future<void>(() async {
      final queuedItems = files
          .map(
            (file) => UploadItemStateModel(
              id: file.path,
              fileName: file.uri.pathSegments.isEmpty
                  ? 'upload'
                  : file.uri.pathSegments.last,
              localPath: file.path,
              progress: 0,
              status: UploadItemStatus.queued,
            ),
          )
          .toList();

      controller.add(
        UploadBatchStateModel(
          items: queuedItems,
          overallProgress: 0,
          uploading: true,
        ),
      );

      var currentItems = [...queuedItems];

      try {
        final fileSizes = <int>[for (final file in files) await file.length()];
        final totalFileBytes = fileSizes.fold<int>(
          0,
          (sum, size) => sum + size,
        );
        var completedBatchBytes = 0;
        final allMedia = <DayMediaModel>[];
        var message = 'uploaded';
        var autoAssignedHighlight = false;
        var highlightImage = '';

        for (var index = 0; index < files.length; index++) {
          final file = files[index];
          final bytes = await file.readAsBytes();
          final descriptor = MultipartUploadFile(
            filename: currentItems[index].fileName,
            bytes: bytes,
          );

          currentItems[index] = currentItems[index].copyWith(
            status: UploadItemStatus.uploading,
            progress: 0,
          );
          controller.add(
            UploadBatchStateModel(
              items: currentItems,
              overallProgress: totalFileBytes == 0
                  ? 0
                  : completedBatchBytes / totalFileBytes,
              uploading: true,
            ),
          );

          final response = await _gql.mutateMultipartWithProgress(
            GqlDocuments.filesUpload,
            variables: {'date': day},
            files: [descriptor],
            onProgress: (sentBytes, totalBytes) {
              if (controller.isClosed) return;
              final perFileProgress = totalBytes <= 0
                  ? 0.0
                  : (sentBytes / totalBytes).clamp(0.0, 1.0);
              final nextItems = [...currentItems];
              nextItems[index] = nextItems[index].copyWith(
                progress: perFileProgress,
                status: perFileProgress >= 1
                    ? UploadItemStatus.processing
                    : UploadItemStatus.uploading,
              );
              controller.add(
                UploadBatchStateModel(
                  items: nextItems,
                  overallProgress: totalFileBytes == 0
                      ? 0
                      : ((completedBatchBytes +
                                    (fileSizes[index] * perFileProgress)) /
                                totalFileBytes)
                            .clamp(0, 1),
                  uploading: true,
                ),
              );
            },
          );

          final payload =
              ((response['files'] as Map<String, dynamic>)['upload']
                  as Map<String, dynamic>);
          final result = UploadBatchResultModel.fromJson(payload);
          message = result.message;
          autoAssignedHighlight =
              autoAssignedHighlight || result.autoAssignedHighlight;
          if (result.highlightImage.isNotEmpty) {
            highlightImage = result.highlightImage;
          }
          allMedia.addAll(result.media);
          DayMediaModel? mediaForFile() {
            for (final media in result.media) {
              if (media.fileName == currentItems[index].fileName) return media;
            }
            return null;
          }

          currentItems[index] = currentItems[index].copyWith(
            progress: 1,
            status: UploadItemStatus.done,
            media: mediaForFile(),
            clearError: true,
          );
          completedBatchBytes += fileSizes[index];
          controller.add(
            UploadBatchStateModel(
              items: currentItems,
              overallProgress: totalFileBytes == 0
                  ? 1
                  : (completedBatchBytes / totalFileBytes).clamp(0, 1),
              uploading: index != files.length - 1,
              result: index == files.length - 1
                  ? UploadBatchResultModel(
                      message: message,
                      media: allMedia,
                      uploadCount: allMedia.length,
                      autoAssignedHighlight: autoAssignedHighlight,
                      highlightImage: highlightImage,
                    )
                  : null,
            ),
          );
        }
      } catch (error) {
        controller.add(
          UploadBatchStateModel(
            items: currentItems.map((item) {
              if (item.status == UploadItemStatus.done) return item;
              return item.copyWith(
                status: UploadItemStatus.failed,
                errorMessage: error.toString().replaceFirst('Exception: ', ''),
              );
            }).toList(),
            overallProgress: 0,
            uploading: false,
            errorMessage: error.toString().replaceFirst('Exception: ', ''),
          ),
        );
      } finally {
        await controller.close();
      }
    });

    return controller.stream;
  }

  @override
  Future<void> updateHighlight(String imagePath) async {
    await _gql.mutate(
      GqlDocuments.updateHighlight,
      variables: {'input': imagePath},
    );
  }
}
