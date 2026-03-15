import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/day_media_model.dart';

abstract class FilesRepository {
  Future<List<DayMediaModel>> getDayFiles(String day, {int first = 300});
  Future<List<DayMediaModel>> listFiles({int first = 2000});
  Future<String> uploadFiles(String day, List<File> files);
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
  Future<String> uploadFiles(String day, List<File> files) async {
    final multipartFiles = <http.MultipartFile>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      multipartFiles.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: file.uri.pathSegments.last,
        ),
      );
    }

    final response = await _gql.mutate(
      GqlDocuments.filesUpload,
      variables: {'date': day, 'files': multipartFiles},
    );

    final payload =
        ((response['files'] as Map<String, dynamic>)['upload']
            as Map<String, dynamic>);
    return (payload['message'] ?? 'uploaded').toString();
  }

  @override
  Future<void> updateHighlight(String imagePath) async {
    await _gql.mutate(
      GqlDocuments.updateHighlight,
      variables: {'input': imagePath},
    );
  }
}
