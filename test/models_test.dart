import 'package:blue_mobile/data/models/story_day_model.dart';
import 'package:blue_mobile/core/config/app_config.dart';
import 'package:blue_mobile/core/network/auth_token_store.dart';
import 'package:blue_mobile/core/network/graphql_service.dart';
import 'package:blue_mobile/data/cache/person_cache_store.dart';
import 'package:blue_mobile/data/models/chat_event_model.dart';
import 'package:blue_mobile/data/models/chat_response_model.dart';
import 'package:blue_mobile/data/models/run_detail_model.dart';
import 'package:blue_mobile/data/models/run_model.dart';
import 'package:blue_mobile/data/models/memory_search_result_model.dart';
import 'package:blue_mobile/data/models/person_model.dart';
import 'package:blue_mobile/data/models/story_day_page_model.dart';
import 'package:blue_mobile/data/repositories/day_repository.dart';
import 'package:blue_mobile/data/repositories/person_repository.dart';
import 'package:blue_mobile/data/repositories/runs_repository.dart';
import 'package:blue_mobile/data/repositories/search_repository.dart';
import 'package:blue_mobile/data/repositories/stories_repository.dart';
import 'package:blue_mobile/features/chat/chat_parsing.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('StoryDayModel parses and maps save payload', () {
    final model = StoryDayModel.fromJson('2026-03-14', {
      'place': 'Berlin',
      'names': 'Alex;Sam',
      'description': 'Great day',
      'keywords': 'travel;run',
      'highlight_image': 'stories_images/2026-03-14/compressed/a.jpg',
      'country': 'DE',
    });

    expect(model.people, ['Alex', 'Sam']);
    expect(model.tags, ['travel', 'run']);
    expect(model.toSaveInput()['place'], 'Berlin');
  });

  test('Polyline decode returns coordinate sequence', () {
    const encoded = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
    final points = decodePolyline(encoded);

    expect(points.length, 3);
    expect(points.first[0].toStringAsFixed(3), '38.500');
    expect(points.first[1].toStringAsFixed(3), '-120.200');
  });

  test('Chat parsing strips metadata lines into attachments', () {
    final parsed = parseChatAttachments(
      'A walk through Lisbon.\n'
      'DATES: 2026-03-10, 2026-03-11\n'
      'IMAGES: ./Blue/stories_images/2026-03-10/PXL_1.jpg',
    );

    expect(parsed.text, 'A walk through Lisbon.');
    expect(parsed.dates, ['2026-03-10', '2026-03-11']);
    expect(
      parsed.images.single.path,
      './Blue/stories_images/2026-03-10/PXL_1.jpg',
    );
    expect(
      parsed.images.single.previewPath,
      './Blue/stories_images/2026-03-10/compressed/PXL_1.jpg',
    );
  });

  test('Chat event preserves status metadata and tool call details', () {
    final status = ChatEventModel.fromJson({
      'type': 'status',
      'stage': 'query',
      'summary': 'Generated SQL query',
      'meta': {
        'sql': 'select * from stories where date = :day',
        'sql_params': {'day': '2026-03-10'},
      },
    });
    final finalResponse = ChatResponseModel.fromJson({
      'type': 'final',
      'text': 'Found it.',
      'tool_calls': [
        {
          'name': 'generate_sql_query',
          'sql': 'select 1',
          'sql_params': {'limit': 1},
          'searched_count': 4,
          'row_count': 1,
          'truncated': false,
        },
      ],
    });

    expect(status.meta?['sql'], contains('select * from stories'));
    expect(
      (status.meta?['sql_params'] as Map<String, dynamic>)['day'],
      '2026-03-10',
    );
    expect(finalResponse.toolCalls.single.name, 'generate_sql_query');
    expect(finalResponse.toolCalls.single.rowCount, 1);
    expect(finalResponse.toolCalls.single.sqlParams['limit'], 1);
  });

  test('Map tile config falls back when Mapbox token is absent', () {
    final light = AppConfig.mapTileConfig('light');
    final dark = AppConfig.mapTileConfig('dark');
    final normal = AppConfig.mapTileConfig('normal');

    expect(AppConfig.hasMapboxToken, isFalse);
    expect(light.urlTemplate, contains('cartocdn.com/light_all'));
    expect(dark.urlTemplate, contains('cartocdn.com/dark_all'));
    expect(normal.urlTemplate, contains('tile.openstreetmap.org'));
  });

  test('Memory search result uses highlight image then file path preview', () {
    final withHighlight = MemorySearchResultModel.fromJson({
      'date': '2026-03-10',
      'highlight_image': 'stories_images/2026-03-10/compressed/a.jpg',
      'path': 'stories_images/2026-03-10/compressed/b.jpg',
      'names': 'Alex;Sam',
      'keywords': 'travel;run',
    });
    final withoutHighlight = MemorySearchResultModel.fromJson({
      'date': '2026-03-10',
      'highlight_image': '',
      'path': 'stories_images/2026-03-10/compressed/b.jpg',
    });

    expect(withHighlight.previewImagePath, contains('a.jpg'));
    expect(withoutHighlight.previewImagePath, contains('b.jpg'));
    expect(withHighlight.people, ['Alex', 'Sam']);
    expect(withHighlight.tags, ['travel', 'run']);
  });

  test('GraphqlDayRepository parses combined day payload', () async {
    final repo = GraphqlDayRepository(
      _FakeGraphqlService({
        'stories': {
          'day': {
            'story': {'place': 'Berlin', 'description': 'Great day'},
          },
        },
        'files': {
          'day': {
            'edges': [
              {
                'node': {
                  'path': './Blue/stories_images/2026-03-14/a.jpg',
                  'date': '2026-03-14',
                  'favorite': true,
                },
              },
            ],
          },
        },
        'runs': {
          'byDate': {
            'edges': [
              {
                'node': {
                  'id': 1,
                  'name': 'Morning Run',
                  'start_date_local': '2026-03-14',
                  'distance': 5000,
                },
              },
            ],
          },
        },
      }),
      const _FakeStoriesRepository(),
      const _FakeRunsRepository(),
    );

    final payload = await repo.getDayCorePayload('2026-03-14');

    expect(payload.story.place, 'Berlin');
    expect(payload.media.single.favorite, isTrue);
    expect(payload.runs.single.name, 'Morning Run');
    expect(payload.events, isEmpty);
    expect(payload.detailsLoaded, isFalse);
  });

  test(
    'MemorySearchRepository falls back to cached day search offline',
    () async {
      final repo = MemorySearchRepository(
        _ThrowingGraphqlService(),
        _FakeStoriesRepository(
          cachedRecentDays: const [
            StoryDayModel(
              date: '2026-03-14',
              place: 'Berlin',
              names: 'Alex;Sam',
              description: 'Great run by the river',
              food: 'Pasta',
              sport: 'Running',
              highlightImage: '',
              keywords: 'travel;run',
              country: 'DE',
            ),
          ],
        ),
      );

      final page = await repo.searchMemories(
        'river',
        mode: MemorySearchMode.days,
        page: 1,
        pageSize: 24,
        columns: const ['description', 'place'],
      );

      expect(page.isOfflineFallback, isTrue);
      expect(page.items.single.date, '2026-03-14');
      expect(page.offlineMessage, contains('10 years'));
    },
  );

  test(
    'GraphqlPersonRepository falls back to cached person detail offline',
    () async {
      final cachedPerson = PersonModel(
        id: 7,
        firstName: 'Alex',
        lastName: 'Meyer',
        birthDate: '',
        deathDate: '',
        relation: 'Friend',
        profession: 'Designer',
        studyProgram: '',
        languages: 'de;en',
        email: '',
        phone: '',
        address: '',
        notes: 'Met in Berlin',
        biography: 'Long-time friend',
      );
      final repo = GraphqlPersonRepository(
        _ThrowingGraphqlService(),
        _FakePersonCacheStore(cachedPeople: [cachedPerson]),
      );

      final payload = await repo.loadDetail(cachedPerson);

      expect(payload.person.displayName, 'Alex Meyer');
      expect(payload.faces, isEmpty);
      expect(payload.images, isEmpty);
    },
  );
}

class _FakeGraphqlService extends GraphqlService {
  _FakeGraphqlService(this.payload) : super(AuthTokenStore());

  final Map<String, dynamic> payload;

  @override
  Future<Map<String, dynamic>> query(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async {
    return payload;
  }
}

class _FakeStoriesRepository implements StoriesRepository {
  const _FakeStoriesRepository({this.cachedRecentDays = const []});

  final List<StoryDayModel> cachedRecentDays;

  @override
  Future<void> cacheDay(StoryDayModel model) async {}

  @override
  Future<StoryDayModel?> getCachedDay(String day) async {
    for (final story in cachedRecentDays) {
      if (story.date == day) return story;
    }
    return null;
  }

  @override
  Future<List<StoryDayModel>> getCachedRecentDays({int limit = 400}) async =>
      cachedRecentDays.take(limit).toList();

  @override
  Future<StoryDayModel> getDay(String day) async => StoryDayModel.empty(day);

  @override
  Future<List<StoryDayModel>> listStories({int first = 500}) async => const [];

  @override
  Future<StoryDayPageModel> listStoriesPage({int first = 120, String? after}) {
    throw UnimplementedError();
  }

  @override
  Future<void> saveDay(StoryDayModel model) async {}

  @override
  Future<void> warmRecentCache({int limit = 3650}) async {}
}

class _FakeRunsRepository implements RunsRepository {
  const _FakeRunsRepository();

  @override
  Future<void> cacheRuns(List<RunModel> runs) async {}

  @override
  Future<RunDetailModel> detail(String runId) {
    throw UnimplementedError();
  }

  @override
  Future<List<RunModel>> getCachedRuns({int limit = 2000}) async => const [];

  @override
  Future<List<RunModel>> listRuns({int first = 2000}) async => const [];

  @override
  Future<({RunDetailModel summary, RunDetailModel detail})> loadDetailBundle(
    String runId,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<List<RunModel>> monthlyRuns({int first = 2000}) async => const [];

  @override
  Future<List<RunModel>> runsForDate(String date, {int first = 50}) async =>
      const [];

  @override
  Future<RunDetailModel> summary(String runId) {
    throw UnimplementedError();
  }

  @override
  Future<void> warmRecentCache({int limitDays = 3650}) async {}
}

class _ThrowingGraphqlService extends GraphqlService {
  _ThrowingGraphqlService() : super(AuthTokenStore());

  @override
  Future<Map<String, dynamic>> query(
    String document, {
    Map<String, dynamic> variables = const {},
  }) async {
    throw Exception('offline');
  }
}

class _FakePersonCacheStore extends PersonCacheStore {
  _FakePersonCacheStore({this.cachedPeople = const []});

  final List<PersonModel> cachedPeople;

  @override
  Future<PersonModel?> readPerson(int id) async {
    for (final person in cachedPeople) {
      if (person.id == id) return person;
    }
    return null;
  }

  @override
  Future<List<PersonModel>> readAllPersons() async => cachedPeople;

  @override
  Future<List<PersonModel>> readPopular({int limit = 12}) async =>
      cachedPeople.take(limit).toList();

  @override
  Future<List<PersonModel>> search(String query, {int limit = 12}) async =>
      cachedPeople.take(limit).toList();

  @override
  Future<void> upsertPeople(List<PersonModel> people) async {}

  @override
  Future<void> upsertPerson(PersonModel person) async {}

  @override
  Future<void> writePopular(List<PersonModel> people) async {}
}
