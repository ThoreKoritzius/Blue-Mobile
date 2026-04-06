import 'dart:typed_data';

import '../cache/person_cache_store.dart';
import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/day_media_model.dart';
import '../models/person_detail_payload_model.dart';
import '../models/person_face_model.dart';
import '../models/person_model.dart';

abstract class PersonRepository {
  Future<PersonModel?> getCachedPerson(int id);
  Future<List<PersonModel>> popular({int first = 12});
  Future<List<PersonModel>> search(String query, {int first = 12});
  Future<PersonDetailPayloadModel> loadDetail(PersonModel person);
  Future<PersonModel> create(PersonModel person);
  Future<PersonModel> update(PersonModel person);
  Future<String> uploadPhoto(int personId, String filename, Uint8List bytes);
}

class GraphqlPersonRepository implements PersonRepository {
  GraphqlPersonRepository(this._gql, this._cacheStore);

  final GraphqlService _gql;
  final PersonCacheStore _cacheStore;

  @override
  Future<PersonModel?> getCachedPerson(int id) => _cacheStore.readPerson(id);

  @override
  Future<List<PersonModel>> popular({int first = 12}) async {
    try {
      final response = await _gql.query(
        GqlDocuments.personPopular,
        variables: {'first': first},
      );
      final edges =
          (((response['persons'] as Map<String, dynamic>)['popular']
                  as Map<String, dynamic>)['edges']
              as List<dynamic>? ??
          const []);
      final people = edges
          .map((edge) => (edge as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(PersonModel.fromJson)
          .where((person) => person.id > 0)
          .toList();
      await _cacheStore.writePopular(people);
      return people;
    } catch (_) {
      final cached = await _cacheStore.readPopular(limit: first);
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
  }

  @override
  Future<List<PersonModel>> search(String query, {int first = 12}) async {
    try {
      final response = await _gql.query(
        GqlDocuments.personSearch,
        variables: {'query': query, 'first': first},
      );
      final edges =
          (((response['persons'] as Map<String, dynamic>)['search']
                  as Map<String, dynamic>)['edges']
              as List<dynamic>? ??
          const []);
      final people = edges
          .map((edge) => (edge as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(PersonModel.fromJson)
          .where((person) => person.id > 0)
          .toList();
      await _cacheStore.upsertPeople(people);
      return people;
    } catch (_) {
      final cached = await _cacheStore.search(query, limit: first);
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
  }

  @override
  Future<PersonDetailPayloadModel> loadDetail(PersonModel person) async {
    try {
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
      await _cacheStore.upsertPerson(person);
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
    } catch (_) {
      final cached = await _cacheStore.readPerson(person.id);
      if (cached != null) {
        return PersonDetailPayloadModel(
          person: cached,
          faces: const [],
          images: const [],
        );
      }
      rethrow;
    }
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
      final personModel = PersonModel.fromJson(payload);
      await _cacheStore.upsertPerson(personModel);
      return personModel;
    }
    await _cacheStore.upsertPerson(person);
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
      final personModel = PersonModel.fromJson(payload);
      await _cacheStore.upsertPerson(personModel);
      return personModel;
    }
    return person;
  }

  @override
  Future<String> uploadPhoto(int personId, String filename, Uint8List bytes) async {
    final data = await _gql.mutateMultipartWithProgress(
      GqlDocuments.uploadPersonPhoto,
      variables: {'personId': personId},
      files: [MultipartUploadFile(filename: filename, bytes: bytes)],
      onProgress: (_, __) {},
    );
    final payload =
        ((data['persons'] as Map<String, dynamic>)['uploadPhoto']
            as Map<String, dynamic>)['data'];
    if (payload is Map<String, dynamic>) {
      return (payload['photo_path'] ?? '').toString();
    }
    return '';
  }
}
