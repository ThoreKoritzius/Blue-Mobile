import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/run_model.dart';

class RunCacheStore {
  RunCacheStore() : _storage = const FlutterSecureStorage();

  static const int maxCachedDays = 3650;
  static const String _indexKey = 'blue_run_cache_index_v2';
  static const String _lastWarmAtKey = 'blue_run_cache_last_warm_at_v2';

  final FlutterSecureStorage _storage;

  /// In-memory cache to avoid repeated sequential platform-channel reads.
  List<RunModel>? _memoryCache;

  Future<List<RunModel>> readAllRuns() async {
    final cached = _memoryCache;
    if (cached != null) return List.unmodifiable(cached);
    final ids = await _readIndex();
    final runs = <RunModel>[];
    for (final id in ids) {
      final raw = await _storage.read(key: _runKey(id));
      if (raw == null || raw.isEmpty) continue;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) continue;
      runs.add(RunModel.fromJson(json));
    }
    _memoryCache = runs;
    return List.unmodifiable(runs);
  }

  Future<List<RunModel>> readRunsForDate(String day) async {
    // Fast path: use memory cache if available to avoid storage I/O.
    final cached = _memoryCache;
    if (cached != null) {
      return cached.where((run) => _runDay(run) == day).toList();
    }
    // Slow path fallback — read index only and filter by matching keys.
    final ids = await _readIndex();
    final runs = <RunModel>[];
    for (final id in ids) {
      final raw = await _storage.read(key: _runKey(id));
      if (raw == null || raw.isEmpty) continue;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) continue;
      final run = RunModel.fromJson(json);
      if (_runDay(run) == day) runs.add(run);
    }
    return runs;
  }

  Future<void> upsertRuns(List<RunModel> runs) async {
    if (runs.isEmpty) return;
    _memoryCache = null;
    final previousIndex = Set<String>.from(await _readIndex());
    final merged = <String, RunModel>{};
    for (final item in await readAllRuns()) {
      merged[item.id] = item;
    }
    // Track which IDs are actually new or changed.
    final dirtyIds = <String>{};
    for (final item in runs) {
      if (item.id.isEmpty) continue;
      if (!merged.containsKey(item.id)) dirtyIds.add(item.id);
      merged[item.id] = item;
    }

    final retainedRuns = merged.values.toList()
      ..sort((a, b) => _runDay(b).compareTo(_runDay(a)));

    final retainedDays = <String>{};
    final retainedIds = <String>[];
    for (final run in retainedRuns) {
      final day = _runDay(run);
      if (day.isEmpty) continue;
      if (retainedDays.length >= maxCachedDays && !retainedDays.contains(day)) {
        continue;
      }
      retainedDays.add(day);
      retainedIds.add(run.id);
      // Only write runs that are new or weren't previously cached.
      if (dirtyIds.contains(run.id) || !previousIndex.contains(run.id)) {
        await _storage.write(
          key: _runKey(run.id),
          value: jsonEncode(run.toJson()),
        );
      }
    }

    for (final id in previousIndex) {
      if (!retainedIds.contains(id)) {
        await _storage.delete(key: _runKey(id));
      }
    }

    final retainedSet = Set<String>.from(retainedIds);
    if (!retainedSet.containsAll(previousIndex) ||
        !previousIndex.containsAll(retainedSet)) {
      await _writeIndex(retainedIds);
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
    _memoryCache = null;
    final ids = await _readIndex();
    for (final id in ids) {
      await _storage.delete(key: _runKey(id));
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

  Future<void> _writeIndex(List<String> ids) {
    return _storage.write(key: _indexKey, value: jsonEncode(ids));
  }

  String _runKey(String id) => 'blue_run_cache_$id';

  String _runDay(RunModel run) => run.startDateLocal.split('T').first;
}
