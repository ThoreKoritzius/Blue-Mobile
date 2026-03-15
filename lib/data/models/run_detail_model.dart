class RunDetailModel {
  const RunDetailModel({required this.runId, required this.payload});

  final String runId;
  final Map<String, dynamic> payload;

  factory RunDetailModel.fromJson(String runId, Map<String, dynamic> json) {
    return RunDetailModel(runId: runId, payload: json);
  }
}
