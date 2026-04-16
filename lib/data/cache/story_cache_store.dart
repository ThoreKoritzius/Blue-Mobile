import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/story_day_model.dart';

class StoryCacheStore {
  StoryCacheStore() : _storage = const FlutterSecureStorage();

  static const int maxCachedDays = 3650;
  static const String _indexKey = 'blue_story_cache_index_v2';
  static const String _lastWarmAtKey = 'blue_story_cache_last_warm_at_v2';

  final FlutterSecureStorage _storage;

  Future<StoryDayModel?> readDay(String day) async {
    final raw = await _storage.read(key: _storyKey(day));
    if (raw == null || raw.isEmpty) return null;
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) return null;
    return StoryDayModel.fromJson(day, json);
  }

  Future<List<StoryDayModel>> readRecentDays({
    int limit = maxCachedDays,
  }) async {
    final index = (await _readIndex()).take(limit);
    final items = <StoryDayModel>[];
    for (final day in index) {
      final raw = await _storage.read(key: _storyKey(day));
      if (raw == null || raw.isEmpty) continue;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) continue;
      items.add(StoryDayModel.fromJson(day, json));
    }
    return items;
  }

  Future<void> upsertStory(StoryDayModel story) async {
    await _storage.write(
      key: _storyKey(story.date),
      value: jsonEncode(story.toJson()),
    );
    final index = await _readIndex();
    if (!index.contains(story.date)) {
      final updated = [...index, story.date]..sort((a, b) => b.compareTo(a));
      await _writeIndex(updated.take(maxCachedDays).toList());
    }
  }

  Future<void> upsertStories(List<StoryDayModel> stories) async {
    if (stories.isEmpty) return;
    final index = await _readIndex();
    final indexSet = index.toSet();
    final existingDates = Set<String>.from(index);

    for (final story in stories) {
      // Only write stories that are new (not already in index).
      if (!existingDates.contains(story.date)) {
        await _storage.write(
          key: _storyKey(story.date),
          value: jsonEncode(story.toJson()),
        );
      }
      indexSet.add(story.date);
    }

    final orderedDates = indexSet.toList()..sort((a, b) => b.compareTo(a));
    final retained = orderedDates.take(maxCachedDays).toList();

    for (final day in index) {
      if (!retained.contains(day)) {
        await _storage.delete(key: _storyKey(day));
      }
    }

    if (retained.length != index.length ||
        !Set<String>.from(retained).containsAll(index)) {
      await _writeIndex(retained);
    }
  }

  Future<DateTime?> readLastWarmAt() async {
    final raw = await _storage.read(key: _lastWarmAtKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> writeLastWarmAt(DateTime value) async {
    await _storage.write(
      key: _lastWarmAtKey,
      value: value.toUtc().toIso8601String(),
    );
  }

  Future<void> clear() async {
    final index = await _readIndex();
    for (final day in index) {
      await _storage.delete(key: _storyKey(day));
    }
    await _storage.delete(key: _indexKey);
    await _storage.delete(key: _lastWarmAtKey);
  }

  Future<List<String>> _readIndex() async {
    final raw = await _storage.read(key: _indexKey);
    if (raw == null || raw.isEmpty) return const <String>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return decoded.map((item) => item.toString()).toList();
  }

  Future<void> _writeIndex(List<String> dates) {
    return _storage.write(key: _indexKey, value: jsonEncode(dates));
  }

  String _storyKey(String day) => 'blue_story_cache_day_$day';
}
