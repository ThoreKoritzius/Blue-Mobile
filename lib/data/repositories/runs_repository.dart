import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/run_detail_model.dart';
import '../models/run_model.dart';

abstract class RunsRepository {
  Future<List<RunModel>> listRuns({int first = 2000});
  Future<List<RunModel>> runsForDate(String date, {int first = 50});
  Future<List<RunModel>> monthlyRuns({int first = 2000});
  Future<({RunDetailModel summary, RunDetailModel detail})> loadDetailBundle(
    String runId,
  );
  Future<RunDetailModel> summary(String runId);
  Future<RunDetailModel> detail(String runId);
}

class GraphqlRunsRepository implements RunsRepository {
  GraphqlRunsRepository(this._gql);

  final GraphqlService _gql;

  @override
  Future<List<RunModel>> listRuns({int first = 2000}) async {
    final response = await _gql.query(
      GqlDocuments.runsList,
      variables: {'first': first},
    );
    final edges =
        (((response['runs'] as Map<String, dynamic>)['list']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);

    return edges
        .map((item) => (item as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map(RunModel.fromJson)
        .toList();
  }

  @override
  Future<List<RunModel>> runsForDate(String date, {int first = 50}) async {
    final response = await _gql.query(
      GqlDocuments.runsByDate,
      variables: {'date': date, 'first': first},
    );
    final edges =
        (((response['runs'] as Map<String, dynamic>)['byDate']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);

    return edges
        .map((item) => (item as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map(RunModel.fromJson)
        .toList();
  }

  @override
  Future<List<RunModel>> monthlyRuns({int first = 2000}) async {
    final response = await _gql.query(
      GqlDocuments.runsMonthly,
      variables: {'first': first},
    );
    final edges =
        (((response['runs'] as Map<String, dynamic>)['monthly']
                as Map<String, dynamic>)['edges']
            as List<dynamic>? ??
        const []);

    return edges
        .map((item) => (item as Map<String, dynamic>)['node'])
        .whereType<Map<String, dynamic>>()
        .map(RunModel.fromJson)
        .toList();
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
