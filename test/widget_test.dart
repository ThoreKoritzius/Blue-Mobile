import 'dart:async';
import 'dart:io';

import 'package:blue_mobile/data/models/day_media_model.dart';
import 'package:blue_mobile/data/models/run_detail_model.dart';
import 'package:blue_mobile/data/models/run_model.dart';
import 'package:blue_mobile/data/repositories/files_repository.dart';
import 'package:blue_mobile/data/repositories/map_repository.dart';
import 'package:blue_mobile/data/repositories/runs_repository.dart';
import 'package:blue_mobile/core/network/auth_token_store.dart';
import 'package:blue_mobile/core/network/graphql_service.dart';
import 'package:blue_mobile/features/auth/login_page.dart';
import 'package:blue_mobile/features/chat/chat_page.dart';
import 'package:blue_mobile/features/map/map_page.dart';
import 'package:blue_mobile/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders login form', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginPage())),
    );

    expect(find.text('Blue Mobile'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('renders chat empty state', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ChatPage())),
      ),
    );

    expect(find.text('Ask about your days'), findsOneWidget);
    expect(find.text('Message Blue...'), findsOneWidget);
  });

  testWidgets('map page shows loading state while repository is pending', (
    tester,
  ) async {
    final runs = Completer<List<RunModel>>();

    await tester.pumpWidget(
      _buildMapHarness(
        _FakeMapRepository(
          imagePageLoader: ({required page, required pageSize}) async =>
              const MapImagePage(points: [], hasMore: false),
          runsLoader: () => runs.future,
        ),
      ),
    );

    expect(find.byKey(const Key('map-loading-text')), findsOneWidget);

    runs.complete(const []);
    await tester.pumpAndSettle();
  }, skip: true);

  testWidgets('map page shows zoom hint when no overlays are available', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildMapHarness(
        _FakeMapRepository(
          imagePageLoader: ({required page, required pageSize}) async =>
              const MapImagePage(points: [], hasMore: false),
          runsLoader: () async => const [],
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('map-loaded-text')), findsOneWidget);
    expect(
      find.textContaining('Zoom in to load image markers'),
      findsOneWidget,
    );
  }, skip: true);

  testWidgets('map page shows error state when repository load fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildMapHarness(
        _FakeMapRepository(
          imagePageLoader: ({required page, required pageSize}) async =>
              const MapImagePage(points: [], hasMore: false),
          runsLoader: () async => throw Exception('boom'),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('map-error-text')), findsOneWidget);
    expect(find.text('Failed to load run routes.'), findsOneWidget);
  }, skip: true);

  testWidgets('map page opens run sheet and navigates to day tab action', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        mapRepositoryProvider.overrideWithValue(
          _FakeMapRepository(
            imagePageLoader: ({required page, required pageSize}) async =>
                const MapImagePage(points: [], hasMore: false),
            runsLoader: () async => const [
              RunModel(
                id: 'run-1',
                name: 'Morning Run',
                startDateLocal: '2026-03-10T08:00:00',
                distance: 5000,
                summaryPolyline: '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
              ),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: MapPage())),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.directions_run));
    await tester.pumpAndSettle();

    expect(find.text('Open day'), findsOneWidget);

    await tester.ensureVisible(find.text('Open day'));
    await tester.tap(find.text('Open day'));
    await tester.pumpAndSettle();

    expect(container.read(selectedTabProvider), 0);
    expect(container.read(selectedDateProvider), DateTime(2026, 3, 10));
  }, skip: true);
}

Widget _buildMapHarness(MapRepository repository) {
  return ProviderScope(
    overrides: [mapRepositoryProvider.overrideWithValue(repository)],
    child: const MaterialApp(home: Scaffold(body: MapPage())),
  );
}

class _FakeMapRepository extends MapRepository {
  _FakeMapRepository({required this.imagePageLoader, required this.runsLoader})
    : super(
        _FakeFilesRepository(loader: () async => const []),
        _FakeRunsRepository(listRunsLoader: () async => const []),
        GraphqlService(AuthTokenStore()),
      );

  final Future<MapImagePage> Function({
    required int page,
    required int pageSize,
  })
  imagePageLoader;
  final Future<List<RunModel>> Function() runsLoader;

  @override
  Future<MapImagePage> searchImagePage({
    required int page,
    required int pageSize,
  }) => imagePageLoader(page: page, pageSize: pageSize);

  @override
  Future<List<RunModel>> loadRuns() => runsLoader();
}

class _FakeRunsRepository implements RunsRepository {
  _FakeRunsRepository({required this.listRunsLoader});

  final Future<List<RunModel>> Function() listRunsLoader;

  @override
  Future<void> cacheRuns(List<RunModel> runs) async {}

  @override
  Future<RunDetailModel> detail(String runId) {
    throw UnimplementedError();
  }

  @override
  Future<List<RunModel>> getCachedRuns({int limit = 2000}) async => const [];

  @override
  Future<List<RunModel>> listRuns({int first = 2000}) => listRunsLoader();

  @override
  Future<List<RunModel>> monthlyRuns({int first = 2000}) async {
    return const [];
  }

  @override
  Future<List<RunModel>> runsForDate(String date, {int first = 50}) async {
    return const [];
  }

  @override
  Future<({RunDetailModel summary, RunDetailModel detail})> loadDetailBundle(
    String runId,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<RunDetailModel> summary(String runId) {
    throw UnimplementedError();
  }

  @override
  Future<void> warmRecentCache({int limitDays = 400}) async {}
}

class _FakeFilesRepository implements FilesRepository {
  _FakeFilesRepository({required this.loader});

  final Future<List<DayMediaModel>> Function() loader;

  @override
  Future<List<DayMediaModel>> getDayFiles(String day, {int first = 300}) =>
      loader();

  @override
  Future<List<DayMediaModel>> listFiles({int first = 2000}) => loader();

  @override
  Future<void> updateHighlight(String imagePath) async {}

  @override
  Future<String> uploadFiles(String day, List<File> files) async => 'ok';
}
