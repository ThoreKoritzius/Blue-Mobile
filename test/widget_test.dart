import 'dart:async';
import 'dart:typed_data';

import 'package:blue/data/models/image_faces_payload_model.dart';
import 'package:blue/data/models/person_detail_payload_model.dart';
import 'package:blue/data/models/person_images_page_model.dart';
import 'package:blue/data/models/run_model.dart';
import 'package:blue/data/models/person_model.dart';
import 'package:blue/data/models/person_photo_upload_result_model.dart';
import 'package:blue/data/models/person_recognition_status_model.dart';
import 'package:blue/core/widgets/fullscreen_image_viewer.dart';
import 'package:blue/data/repositories/files_repository.dart';
import 'package:blue/data/repositories/map_repository.dart';
import 'package:blue/data/repositories/person_repository.dart';
import 'package:blue/core/network/auth_token_store.dart';
import 'package:blue/core/network/graphql_service.dart';
import 'package:blue/features/auth/login_page.dart';
import 'package:blue/features/chat/chat_page.dart';
import 'package:blue/features/map/map_page.dart';
import 'package:blue/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders login form', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LoginPage())),
    );

    expect(find.text('Welcome to Blue'), findsOneWidget);
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
          runsLoader: () async => throw Exception('boom'),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('map-error-text')), findsOneWidget);
    expect(find.text('Failed to load run routes.'), findsOneWidget);
  }, skip: true);

  testWidgets('fullscreen viewer info sheet shows named and unknown faces', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FullscreenImageViewer(
          images: const [
            ImageViewerItem(
              fullUrl: 'https://example.com/full.jpg',
              thumbnailUrl: 'https://example.com/thumb.jpg',
              fileName: 'full.jpg',
              path: './Blue/stories_images/2026-03-14/full.jpg',
              date: '2026-03-14',
            ),
          ],
          initialIndex: 0,
          httpHeaders: const {},
          fetchImageInfo: (_) async =>
              const ImageInfoResult(file: {}, exif: {}),
          fetchImageFaces: (_) async => ImageFacesPayloadModel.fromJson({
            'path': './Blue/stories_images/2026-03-14/full.jpg',
            'status': 'ready',
            'message': 'Detected 2 faces.',
            'faces': [
              {
                'face_id': 1,
                'path': './Blue/stories_images/2026-03-14/full.jpg',
                'crop_path': '',
                'person_id': 7,
                'person_name': 'Ada Lovelace',
                'bbox': [0, 0, 10, 10],
              },
              {
                'face_id': 2,
                'path': './Blue/stories_images/2026-03-14/full.jpg',
                'crop_path': '',
                'person_id': null,
                'person_name': '',
                'bbox': [10, 10, 10, 10],
              },
            ],
          }),
          unlabelFace: (_) async {},
          reassignFace: (_, __, {isReference = false}) async {},
          personRepository: _FakePersonRepository(),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Details'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('People in this photo'), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(find.text('Unknown person'), findsOneWidget);
  });

  testWidgets('map page opens run sheet and navigates to day tab action', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        mapRepositoryProvider.overrideWithValue(
          _FakeMapRepository(
            runsLoader: () async => const [
              RunModel(
                id: 'run-1',
                name: 'Morning Run',
                startDateLocal: '2026-03-10T08:00:00',
                distance: 5000,
                summaryPolyline: '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
                movingTime: 1500,
                averageSpeed: 3.33,
                startTime: '08:00',
                source: 'strava',
                sourceLabel: 'Strava',
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
  _FakeMapRepository({required this.runsLoader})
    : super(GraphqlService(AuthTokenStore()));

  final Future<List<RunModel>> Function() runsLoader;

  @override
  Future<List<RunModel>> loadRuns({
    String? dateFrom,
    String? dateTo,
    bool forceRefresh = false,
  }) => runsLoader();
}

class _FakePersonRepository implements PersonRepository {
  @override
  Future<PersonModel?> getCachedPerson(int id) async => null;

  @override
  Future<List<PersonModel>> popular({int first = 12}) async => const [];

  @override
  Future<List<PersonModel>> search(String query, {int first = 12}) async =>
      const [];

  @override
  Future<PersonDetailPayloadModel> loadDetail(PersonModel person) {
    throw UnimplementedError();
  }

  @override
  Future<PersonImagesPageModel> loadPersonImagesPage(
    int personId, {
    required int page,
    required int pageSize,
    String mode = 'auto',
  }) {
    throw UnimplementedError();
  }

  @override
  Future<PersonRecognitionStatusModel> loadRecognitionStatus(int personId) {
    throw UnimplementedError();
  }

  @override
  Future<PersonModel> create(PersonModel person) async => person;

  @override
  Future<PersonModel> update(PersonModel person) async => person;

  @override
  Future<PersonPhotoUploadResultModel> uploadPhoto(
    int personId,
    String filename,
    Uint8List bytes,
  ) {
    throw UnimplementedError();
  }
}
