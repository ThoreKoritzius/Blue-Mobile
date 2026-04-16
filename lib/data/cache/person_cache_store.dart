import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/person_model.dart';

class PersonCacheStore {
  PersonCacheStore() : _storage = const FlutterSecureStorage();

  static const String _indexKey = 'blue_person_cache_index_v1';
  static const String _popularKey = 'blue_person_cache_popular_v1';

  final FlutterSecureStorage _storage;

  /// In-memory cache to avoid repeated sequential platform-channel reads.
  List<PersonModel>? _memoryCache;

  Future<PersonModel?> readPerson(int id) async {
    final raw = await _storage.read(key: _personKey(id));
    if (raw == null || raw.isEmpty) return null;
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) return null;
    return PersonModel.fromJson(json);
  }

  Future<List<PersonModel>> readAllPersons() async {
    final cached = _memoryCache;
    if (cached != null) return List.unmodifiable(cached);
    final ids = await _readIndex();
    final people = <PersonModel>[];
    for (final id in ids) {
      final person = await readPerson(id);
      if (person != null) {
        people.add(person);
      }
    }
    _memoryCache = people;
    return List.unmodifiable(people);
  }

  Future<List<PersonModel>> readPopular({int limit = 12}) async {
    final ids = await _readPopularIds();
    final people = <PersonModel>[];
    for (final id in ids.take(limit)) {
      final person = await readPerson(id);
      if (person != null) {
        people.add(person);
      }
    }
    return people;
  }

  Future<List<PersonModel>> search(String query, {int limit = 12}) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return readPopular(limit: limit);
    final people = await readAllPersons();
    final matches = people.where((person) {
      final haystack = [
        person.displayName,
        person.relation,
        person.profession,
        person.studyProgram,
        person.languages,
        person.email,
        person.phone,
        person.address,
        person.notes,
        person.biography,
      ].join('\n').toLowerCase();
      return haystack.contains(needle);
    }).toList()..sort((a, b) => a.displayName.compareTo(b.displayName));
    return matches.take(limit).toList();
  }

  Future<void> upsertPerson(PersonModel person) async {
    await upsertPeople([person]);
  }

  Future<void> upsertPeople(List<PersonModel> people) async {
    if (people.isEmpty) return;
    _memoryCache = null;
    final index = await _readIndex();
    final knownIds = {...index};
    for (final person in people) {
      if (person.id <= 0) continue;
      knownIds.add(person.id);
      await _storage.write(
        key: _personKey(person.id),
        value: jsonEncode(person.toJson()),
      );
    }
    await _writeIndex(knownIds.toList()..sort());
  }

  Future<void> writePopular(List<PersonModel> people) async {
    await upsertPeople(people);
    final ids = people
        .where((person) => person.id > 0)
        .map((person) => person.id)
        .toList();
    await _storage.write(key: _popularKey, value: jsonEncode(ids));
  }

  Future<void> clear() async {
    _memoryCache = null;
    final ids = await _readIndex();
    for (final id in ids) {
      await _storage.delete(key: _personKey(id));
    }
    await _storage.delete(key: _indexKey);
    await _storage.delete(key: _popularKey);
  }

  Future<List<int>> _readIndex() async {
    final raw = await _storage.read(key: _indexKey);
    if (raw == null || raw.isEmpty) return const <int>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <int>[];
    return decoded
        .map((item) => int.tryParse(item.toString()) ?? 0)
        .where((item) => item > 0)
        .toList();
  }

  Future<void> _writeIndex(List<int> ids) {
    return _storage.write(key: _indexKey, value: jsonEncode(ids));
  }

  Future<List<int>> _readPopularIds() async {
    final raw = await _storage.read(key: _popularKey);
    if (raw == null || raw.isEmpty) return const <int>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <int>[];
    return decoded
        .map((item) => int.tryParse(item.toString()) ?? 0)
        .where((item) => item > 0)
        .toList();
  }

  String _personKey(int id) => 'blue_person_cache_$id';
}
