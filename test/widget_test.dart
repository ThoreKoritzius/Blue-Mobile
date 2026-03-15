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
    final images = Completer<List<MapPoint>>();
    final runs = Completer<List<RunModel>>();

    await tester.pumpWidget(
      _buildMapHarness(
        _FakeMapRepository(
          photoPointsLoader: () => images.future,
          runsLoader: () => runs.future,
        ),
      ),
    );

    expect(find.textContaining('Loading... images 0, runs 0'), findsOneWidget);

    images.complete(const []);
    runs.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('map page shows empty state when no overlays are returned', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildMapHarness(
        _FakeMapRepository(
          photoPointsLoader: () async => const [],
          runsLoader: () async => const [],
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('No map data found.'), findsOneWidget);
  });

  testWidgets('map page shows error state when repository load fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildMapHarness(
        _FakeMapRepository(
          photoPointsLoader: () async => throw Exception('boom'),
          runsLoader: () async => const [],
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Failed to load map images.'), findsOneWidget);
  });

  testWidgets('map page opens image sheet and navigates to day tab action', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        mapRepositoryProvider.overrideWithValue(
          _FakeMapRepository(
            photoPointsLoader: () async => const [
              MapPoint(
                date: '2026-03-10',
                lat: 52.52,
                lon: 13.405,
                path:
                    'https://blue.the-centaurus.com/api/images/2026-03-10/a.jpg',
              ),
            ],
            runsLoader: () async => const [],
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

    await tester.tap(find.byIcon(Icons.photo_camera));
    await tester.pumpAndSettle();

    expect(find.text('Open day'), findsOneWidget);

    await tester.ensureVisible(find.text('Open day'));
    await tester.tap(find.text('Open day'));
    await tester.pumpAndSettle();

    expect(container.read(selectedTabProvider), 0);
    expect(container.read(selectedDateProvider), DateTime(2026, 3, 10));
  });
}

Widget _buildMapHarness(MapRepository repository) {
  return ProviderScope(
    overrides: [mapRepositoryProvider.overrideWithValue(repository)],
    child: const MaterialApp(home: Scaffold(body: MapPage())),
  );
}

class _FakeMapRepository extends MapRepository {
  _FakeMapRepository({
    required this.photoPointsLoader,
    required this.runsLoader,
  }) : super(
         _FakeFilesRepository(loader: () async => const []),
         _FakeRunsRepository(listRunsLoader: () async => const []),
         GraphqlService(AuthTokenStore()),
       );

  final Future<List<MapPoint>> Function() photoPointsLoader;
  final Future<List<RunModel>> Function() runsLoader;

  Future<List<MapPoint>> loadPhotoPoints() => photoPointsLoader();

  @override
  Future<List<RunModel>> loadRuns() => runsLoader();
}

class _FakeRunsRepository implements RunsRepository {
  _FakeRunsRepository({required this.listRunsLoader});

  final Future<List<RunModel>> Function() listRunsLoader;

  @override
  Future<RunDetailModel> detail(String runId) {
    throw UnimplementedError();
  }

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
