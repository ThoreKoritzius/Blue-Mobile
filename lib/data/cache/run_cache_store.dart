import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/run_model.dart';

class RunCacheStore {
  RunCacheStore() : _storage = const FlutterSecureStorage();

  static const int maxCachedDays = 3650;
  static const String _indexKey = 'blue_run_cache_index_v1';
  static const String _lastWarmAtKey = 'blue_run_cache_last_warm_at_v1';

  final FlutterSecureStorage _storage;

  Future<List<RunModel>> readAllRuns() async {
    final ids = await _readIndex();
    final runs = <RunModel>[];
    for (final id in ids) {
      final raw = await _storage.read(key: _runKey(id));
      if (raw == null || raw.isEmpty) continue;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) continue;
      runs.add(RunModel.fromJson(json));
    }
    return runs;
  }

  Future<List<RunModel>> readRunsForDate(String day) async {
    final runs = await readAllRuns();
    return runs.where((run) => _runDay(run) == day).toList();
  }

  Future<void> upsertRuns(List<RunModel> runs) async {
    if (runs.isEmpty) return;
    final merged = <String, RunModel>{};
    for (final item in await readAllRuns()) {
      merged[item.id] = item;
    }
    for (final item in runs) {
      if (item.id.isEmpty) continue;
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
      await _storage.write(
        key: _runKey(run.id),
        value: jsonEncode(run.toJson()),
      );
    }

    final previousIndex = await _readIndex();
    for (final id in previousIndex) {
      if (!retainedIds.contains(id)) {
        await _storage.delete(key: _runKey(id));
      }
    }

    await _writeIndex(retainedIds);
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
