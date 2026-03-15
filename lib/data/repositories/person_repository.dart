import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/day_media_model.dart';
import '../models/person_detail_payload_model.dart';
import '../models/person_face_model.dart';
import '../models/person_model.dart';

abstract class PersonRepository {
  Future<List<PersonModel>> popular({int first = 12});
  Future<List<PersonModel>> search(String query, {int first = 12});
  Future<PersonDetailPayloadModel> loadDetail(PersonModel person);
  Future<PersonModel> create(PersonModel person);
  Future<PersonModel> update(PersonModel person);
}

class GraphqlPersonRepository implements PersonRepository {
  GraphqlPersonRepository(this._gql);

  final GraphqlService _gql;

  @override
  Future<List<PersonModel>> popular({int first = 12}) async {
    final response = await _gql.query(
      GqlDocuments.personPopular,
      variables: {'first': first},
    );
    final edges =
        (((response['persons'] as Map<String, dynamic>)['popular']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);
    return edges
        .map((edge) => (edge as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map(PersonModel.fromJson)
        .where((person) => person.id > 0)
        .toList();
  }

  @override
  Future<List<PersonModel>> search(String query, {int first = 12}) async {
    final response = await _gql.query(
      GqlDocuments.personSearch,
      variables: {'query': query, 'first': first},
    );
    final edges =
        (((response['persons'] as Map<String, dynamic>)['search']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);
    return edges
        .map((edge) => (edge as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map(PersonModel.fromJson)
        .where((person) => person.id > 0)
        .toList();
  }

  @override
  Future<PersonDetailPayloadModel> loadDetail(PersonModel person) async {
    final response = await _gql.query(
      GqlDocuments.personDetailBundle,
      variables: {'personId': person.id},
    );
    final facesRoot = response['faces'] as Map<String, dynamic>? ?? const {};
    final faceEdges =
        ((facesRoot['personFaces'] as Map<String, dynamic>?)?['edges']
            as List<dynamic>? ??
        const []);
    final imageEdges =
        ((facesRoot['personImages'] as Map<String, dynamic>?)?['edges']
            as List<dynamic>? ??
        const []);

    return PersonDetailPayloadModel(
      person: person,
      faces: faceEdges
          .map((edge) => (edge as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(PersonFaceModel.fromJson)
          .toList(),
      images: imageEdges
          .map((edge) => (edge as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(DayMediaModel.fromJson)
          .toList(),
    );
  }

  @override
  Future<PersonModel> update(PersonModel person) async {
    final response = await _gql.mutate(
      GqlDocuments.updatePerson,
      variables: {'personId': person.id, 'input': person.toGraphqlInput()},
    );
    final payload =
        ((response['persons'] as Map<String, dynamic>)['update']
            as Map<String, dynamic>)['data'];
    if (payload is Map<String, dynamic>) {
      return PersonModel.fromJson(payload);
    }
    return person;
  }

  @override
  Future<PersonModel> create(PersonModel person) async {
    final response = await _gql.mutate(
      GqlDocuments.createPerson,
      variables: {'input': person.toGraphqlInput()},
    );
    final payload =
        ((response['persons'] as Map<String, dynamic>)['create']
            as Map<String, dynamic>)['data'];
    if (payload is Map<String, dynamic>) {
      return PersonModel.fromJson(payload);
    }
    return person;
  }
}
