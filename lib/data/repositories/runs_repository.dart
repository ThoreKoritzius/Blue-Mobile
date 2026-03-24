import '../cache/run_cache_store.dart';
import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/run_detail_model.dart';
import '../models/run_model.dart';

abstract class RunsRepository {
  Future<void> cacheRuns(List<RunModel> runs);
  Future<List<RunModel>> getCachedRuns({int limit = 2000});
  Future<List<RunModel>> listRuns({int first = 2000});
  Future<List<RunModel>> runsForDate(String date, {int first = 50});
  Future<List<RunModel>> monthlyRuns({int first = 2000});
  Future<void> warmRecentCache({int limitDays = RunCacheStore.maxCachedDays});
  Future<({RunDetailModel summary, RunDetailModel detail})> loadDetailBundle(
    String runId,
  );
  Future<RunDetailModel> summary(String runId);
  Future<RunDetailModel> detail(String runId);
}

class GraphqlRunsRepository implements RunsRepository {
  GraphqlRunsRepository(this._gql, this._cacheStore);

  final GraphqlService _gql;
  final RunCacheStore _cacheStore;

  @override
  Future<void> cacheRuns(List<RunModel> runs) {
    return _cacheStore.upsertRuns(runs);
  }

  @override
  Future<List<RunModel>> getCachedRuns({int limit = 2000}) async {
    final runs = await _cacheStore.readAllRuns();
    return runs.take(limit).toList();
  }

  @override
  Future<List<RunModel>> listRuns({int first = 2000}) async {
    try {
      final response = await _gql.query(
        GqlDocuments.runsList,
        variables: {'first': first},
      );
      final edges =
          (((response['runs'] as Map<String, dynamic>)['list']
                  as Map<String, dynamic>)['edges']
              as List<dynamic>? ??
          const []);

      final runs = edges
          .map((item) => (item as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(RunModel.fromJson)
          .toList();
      await _cacheStore.upsertRuns(runs);
      return runs;
    } catch (_) {
      final cached = await _cacheStore.readAllRuns();
      if (cached.isNotEmpty) return cached.take(first).toList();
      rethrow;
    }
  }

  @override
  Future<List<RunModel>> runsForDate(String date, {int first = 50}) async {
    try {
      final response = await _gql.query(
        GqlDocuments.runsByDate,
        variables: {'date': date, 'first': first},
      );
      final edges =
          (((response['runs'] as Map<String, dynamic>)['byDate']
                  as Map<String, dynamic>)['edges']
              as List<dynamic>? ??
          const []);

      final runs = edges
          .map((item) => (item as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(RunModel.fromJson)
          .toList();
      await _cacheStore.upsertRuns(runs);
      return runs;
    } catch (_) {
      final cached = await _cacheStore.readRunsForDate(date);
      if (cached.isNotEmpty) return cached.take(first).toList();
      rethrow;
    }
  }

  @override
  Future<List<RunModel>> monthlyRuns({int first = 2000}) async {
    try {
      final response = await _gql.query(
        GqlDocuments.runsMonthly,
        variables: {'first': first},
      );
      final edges =
          (((response['runs'] as Map<String, dynamic>)['monthly']
                  as Map<String, dynamic>)['edges']
              as List<dynamic>? ??
          const []);

      final runs = edges
          .map((item) => (item as Map<String, dynamic>)['node'])
          .whereType<Map<String, dynamic>>()
          .map(RunModel.fromJson)
          .toList();
      await _cacheStore.upsertRuns(runs);
      return runs;
    } catch (_) {
      final cached = await _cacheStore.readAllRuns();
      if (cached.isNotEmpty) return cached.take(first).toList();
      rethrow;
    }
  }

  @override
  Future<void> warmRecentCache({
    int limitDays = RunCacheStore.maxCachedDays,
  }) async {
    final lastWarmAt = await _cacheStore.readLastWarmAt();
    final cachedCount = (await _cacheStore.readAllRuns()).length;
    final minimumExpected = (limitDays / 7).floor();
    if (cachedCount >= minimumExpected &&
        lastWarmAt != null &&
        DateTime.now().toUtc().difference(lastWarmAt) <
            const Duration(minutes: 20)) {
      return;
    }
    final runs = await listRuns(first: limitDays * 4);
    await _cacheStore.upsertRuns(runs);
    await _cacheStore.writeLastWarmAt(DateTime.now().toUtc());
  }

  @override
  Future<({RunDetailModel summary, RunDetailModel detail})> loadDetailBundle(
    String runId,
  ) async {
    final response = await _gql.query(
      GqlDocuments.runBundle,
      variables: {'runId': runId},
    );
    final runs = response['runs'] as Map<String, dynamic>? ?? const {};

    final summaryRaw = runs['summary'];
    final summary =
        summaryRaw is List &&
            summaryRaw.isNotEmpty &&
            summaryRaw.first is Map<String, dynamic>
        ? RunDetailModel.fromJson(
            runId,
            summaryRaw.first as Map<String, dynamic>,
          )
        : summaryRaw is Map<String, dynamic>
        ? RunDetailModel.fromJson(runId, summaryRaw)
        : RunDetailModel.fromJson(runId, const {});

    final detail = RunDetailModel.fromJson(
      runId,
      runs['detail'] as Map<String, dynamic>? ?? const {},
    );
    return (summary: summary, detail: detail);
  }

  @override
  Future<RunDetailModel> summary(String runId) async {
    final response = await _gql.query(
      GqlDocuments.runSummary,
      variables: {'runId': runId},
    );
    final raw = (response['runs'] as Map<String, dynamic>)['summary'];
    if (raw is List && raw.isNotEmpty && raw.first is Map<String, dynamic>) {
      return RunDetailModel.fromJson(runId, raw.first as Map<String, dynamic>);
    }
    if (raw is Map<String, dynamic>) {
      return RunDetailModel.fromJson(runId, raw);
    }
    return RunDetailModel.fromJson(runId, const {});
  }

  @override
  Future<RunDetailModel> detail(String runId) async {
    final response = await _gql.query(
      GqlDocuments.runDetail,
      variables: {'runId': runId},
    );
    final payload =
        ((response['runs'] as Map<String, dynamic>)['detail']
            as Map<String, dynamic>? ??
        {});
    return RunDetailModel.fromJson(runId, payload);
  }
}
