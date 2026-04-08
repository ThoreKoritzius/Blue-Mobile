import '../../core/network/graphql_service.dart';
import '../graphql/documents.dart';
import '../models/data_source_status_model.dart';

abstract class SystemRepository {
  Future<List<DataSourceStatusModel>> dataSources();
}

class GraphqlSystemRepository implements SystemRepository {
  GraphqlSystemRepository(this._gql);

  final GraphqlService _gql;

  @override
  Future<List<DataSourceStatusModel>> dataSources() async {
    final response = await _gql.query(GqlDocuments.systemDataSources);
    final payload =
        ((response['system'] as Map<String, dynamic>?)?['dataSources'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const <Map<String, dynamic>>[];

    return payload.map(DataSourceStatusModel.fromJson).toList();
  }
}
