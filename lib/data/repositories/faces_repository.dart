import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/image_faces_payload_model.dart';

abstract class FacesRepository {
  Future<ImageFacesPayloadModel> getImageFaces(String path);
  Future<void> unlabelFace(int faceId);
  Future<void> reassignFace(
    int faceId,
    int personId, {
    bool isReference = false,
  });
}

class GraphqlFacesRepository implements FacesRepository {
  GraphqlFacesRepository(this._gql);

  final GraphqlService _gql;

  @override
  Future<ImageFacesPayloadModel> getImageFaces(String path) async {
    final response = await _gql.query(
      GqlDocuments.facesByPath,
      variables: {'path': path},
    );
    final facesRoot = response['faces'] as Map<String, dynamic>? ?? const {};
    final payload = facesRoot['byPath'];
    if (payload is Map<String, dynamic>) {
      return ImageFacesPayloadModel.fromJson(payload);
    }
    return ImageFacesPayloadModel.fromJson({
      'path': path,
      'status': 'pending',
      'message': '',
      'faces': const [],
    });
  }

  @override
  Future<void> unlabelFace(int faceId) async {
    await _gql.mutate(
      GqlDocuments.facesUnlabel,
      variables: {'faceId': faceId},
    );
  }

  @override
  Future<void> reassignFace(
    int faceId,
    int personId, {
    bool isReference = false,
  }) async {
    await _gql.mutate(
      GqlDocuments.facesReassign,
      variables: {
        'faceId': faceId,
        'personId': personId,
        'isReference': isReference,
      },
    );
  }
}
