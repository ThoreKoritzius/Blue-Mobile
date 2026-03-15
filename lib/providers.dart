import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/network/auth_token_store.dart';
import 'core/network/graphql_service.dart';
import 'data/models/auth_session.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/calendar_repository.dart';
import 'data/repositories/chat_repository.dart';
import 'data/repositories/day_repository.dart';
import 'data/repositories/files_repository.dart';
import 'data/repositories/map_repository.dart';
import 'data/repositories/person_repository.dart';
import 'data/repositories/runs_repository.dart';
import 'data/repositories/search_repository.dart';
import 'data/repositories/stories_repository.dart';
import 'features/auth/auth_error_storage.dart';

final selectedDateProvider = StateProvider<DateTime>((ref) => DateTime.now());
final selectedTabProvider = StateProvider<int>((ref) => 0);
final dayAppBarAccentProvider = StateProvider<Color>(
  (ref) => const Color(0xFF174EA6),
);
final themeModeProvider = NotifierProvider<AppThemeModeController, ThemeMode>(
  AppThemeModeController.new,
);

final authTokenStoreProvider = Provider<AuthTokenStore>(
  (ref) => AuthTokenStore(),
);

final graphqlServiceProvider = Provider<GraphqlService>((ref) {
  final tokenStore = ref.watch(authTokenStoreProvider);
  return GraphqlService(tokenStore);
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return GraphqlAuthRepository(
    ref.watch(graphqlServiceProvider),
    ref.watch(authTokenStoreProvider),
  );
});

final storiesRepositoryProvider = Provider<StoriesRepository>((ref) {
  return GraphqlStoriesRepository(ref.watch(graphqlServiceProvider));
});

final filesRepositoryProvider = Provider<FilesRepository>((ref) {
  return GraphqlFilesRepository(ref.watch(graphqlServiceProvider));
});

final runsRepositoryProvider = Provider<RunsRepository>((ref) {
  return GraphqlRunsRepository(ref.watch(graphqlServiceProvider));
});

final calendarRepositoryProvider = Provider<CalendarRepository>((ref) {
  return GraphqlCalendarRepository(ref.watch(graphqlServiceProvider));
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return StreamingChatRepository(ref.watch(graphqlServiceProvider));
});

final dayRepositoryProvider = Provider<DayRepository>((ref) {
  return GraphqlDayRepository(ref.watch(graphqlServiceProvider));
});

final personRepositoryProvider = Provider<PersonRepository>((ref) {
  return GraphqlPersonRepository(ref.watch(graphqlServiceProvider));
});

final mapRepositoryProvider = Provider<MapRepository>((ref) {
  return MapRepository(
    ref.watch(filesRepositoryProvider),
    ref.watch(runsRepositoryProvider),
    ref.watch(graphqlServiceProvider),
  );
});

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return MemorySearchRepository(ref.watch(graphqlServiceProvider));
});

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthSession?>(AuthController.new);
final authUiStateProvider = NotifierProvider<AuthUiController, AuthUiState>(
  AuthUiController.new,
);

enum AuthStage {
  idle,
  checkingOauth,
  oauthMissing,
  credentialSubmitting,
  success,
  error,
}

class AuthFailure {
  const AuthFailure({required this.code, required this.message});

  final String code;
  final String message;
}

class AuthResult {
  const AuthResult._({this.session, this.failure});

  final AuthSession? session;
  final AuthFailure? failure;

  bool get isSuccess => session != null;

  factory AuthResult.success(AuthSession session) =>
      AuthResult._(session: session);

  factory AuthResult.failure(String code, String message) => AuthResult._(
    failure: AuthFailure(code: code, message: message),
  );
}

class AuthUiState {
  const AuthUiState({
    required this.stage,
    required this.oauthReady,
    required this.errorMessage,
    required this.lastFailure,
  });

  final AuthStage stage;
  final bool oauthReady;
  final String? errorMessage;
  final AuthFailure? lastFailure;

  bool get isSubmitting => stage == AuthStage.credentialSubmitting;
  bool get isCheckingOauth => stage == AuthStage.checkingOauth;

  AuthUiState copyWith({
    AuthStage? stage,
    bool? oauthReady,
    String? errorMessage,
    bool clearError = false,
    AuthFailure? lastFailure,
    bool clearFailure = false,
  }) {
    return AuthUiState(
      stage: stage ?? this.stage,
      oauthReady: oauthReady ?? this.oauthReady,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    );
  }

  static const initial = AuthUiState(
    stage: AuthStage.idle,
    oauthReady: false,
    errorMessage: null,
    lastFailure: null,
  );
}

class AuthController extends AsyncNotifier<AuthSession?> {
  @override
  Future<AuthSession?> build() async {
    return ref.read(authRepositoryProvider).checkSession();
  }

  void setSession(AuthSession? session) {
    state = AsyncData(session);
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).logout();
    ref.read(authUiStateProvider.notifier).clearError();
    state = const AsyncData(null);
  }
}

class AuthUiController extends Notifier<AuthUiState> {
  bool _initialized = false;

  void _log(String message) {
    debugPrint('[AUTH] $message');
  }

  @override
  AuthUiState build() {
    return AuthUiState.initial;
  }

  Future<void> initialize({String? initialError}) async {
    _log('initialize called (initialized=$_initialized)');
    if (initialError != null && initialError.trim().isNotEmpty) {
      _log('initialize initialError="$initialError"');
      _setFailure('initial_error', initialError, stage: AuthStage.error);
    }

    final persisted = readPersistedAuthError();
    if (persisted != null && persisted.trim().isNotEmpty) {
      _setFailure('persisted_error', persisted, stage: AuthStage.error);
    }

    if (_initialized) return;
    _initialized = true;
    if (kIsWeb) {
      _log('initialize running checkOauth (web)');
      await checkOauth();
    } else {
      final hasGatewayProof = await ref
          .read(authRepositoryProvider)
          .hasStoredGatewayProof();
      _log('initialize mobile gatewayProof=$hasGatewayProof');
      if (hasGatewayProof) {
        state = state.copyWith(
          stage: AuthStage.idle,
          oauthReady: true,
          clearError: true,
          clearFailure: true,
        );
      }
    }
  }

  Future<void> checkOauth() async {
    _log('checkOauth start');
    state = state.copyWith(
      stage: AuthStage.checkingOauth,
      clearError: true,
      clearFailure: true,
    );
    writePersistedAuthError(null);

    try {
      final ready = await ref
          .read(authRepositoryProvider)
          .checkGatewaySession()
          .timeout(const Duration(seconds: 8));
      _log('checkOauth result oauthReady=$ready');
      if (ready) {
        state = state.copyWith(
          stage: AuthStage.idle,
          oauthReady: true,
          clearError: true,
          clearFailure: true,
        );
        writePersistedAuthError(null);
      } else {
        _setFailure(
          'oauth_missing',
          'Google OAuth session missing. Complete step 1 and retry.',
          stage: AuthStage.oauthMissing,
          oauthReady: false,
        );
      }
    } on TimeoutException {
      _log('checkOauth timeout');
      _setFailure(
        'oauth_timeout',
        'OAuth check timed out. Please retry.',
        stage: AuthStage.error,
        oauthReady: false,
      );
    } catch (error) {
      _log('checkOauth error=$error');
      _setFailure(
        'oauth_check_failed',
        _normalizeError(error),
        stage: AuthStage.error,
        oauthReady: false,
      );
    }
  }

  Future<void> awaitOauthReadyAfterLaunch() async {
    _log('awaitOauthReadyAfterLaunch start');
    state = state.copyWith(
      stage: AuthStage.checkingOauth,
      clearError: true,
      clearFailure: true,
    );
    writePersistedAuthError(null);

    for (var i = 0; i < 24; i += 1) {
      try {
        final ready = await ref
            .read(authRepositoryProvider)
            .checkGatewaySession()
            .timeout(const Duration(seconds: 4));
        if (ready) {
          _log('awaitOauthReadyAfterLaunch success');
          state = state.copyWith(
            stage: AuthStage.idle,
            oauthReady: true,
            clearError: true,
            clearFailure: true,
          );
          writePersistedAuthError(null);
          return;
        }
      } catch (_) {
        // Ignore single probe failures while user is still authenticating.
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    _setFailure(
      'oauth_missing',
      'OAuth session still missing after waiting. Complete Google login and press "Check OAuth session".',
      stage: AuthStage.oauthMissing,
      oauthReady: false,
    );
  }

  Future<void> completeMobileOauth(String code) async {
    _log('completeMobileOauth start');
    state = state.copyWith(
      stage: AuthStage.checkingOauth,
      clearError: true,
      clearFailure: true,
      oauthReady: false,
    );
    writePersistedAuthError(null);
    try {
      await ref.read(authRepositoryProvider).exchangeMobileCode(code);
      _log('completeMobileOauth success');
      state = state.copyWith(
        stage: AuthStage.idle,
        oauthReady: true,
        clearError: true,
        clearFailure: true,
      );
      writePersistedAuthError(null);
    } catch (error) {
      _log('completeMobileOauth error=$error');
      _setFailure(
        'oauth_exchange_failed',
        _normalizeError(error),
        stage: AuthStage.error,
        oauthReady: false,
      );
    }
  }

  Future<AuthResult> signIn({
    required String username,
    required String password,
  }) async {
    final user = username.trim();
    _log('signIn start user="$user" oauthReady=${state.oauthReady}');
    if (user.isEmpty || password.isEmpty) {
      final message = 'Enter username and password.';
      _setFailure(
        'validation',
        message,
        stage: AuthStage.error,
        oauthReady: state.oauthReady,
      );
      return AuthResult.failure('validation', message);
    }

    if (!state.oauthReady) {
      final message = 'OAuth stage incomplete. Use Google sign-in first.';
      _setFailure(
        'oauth_required',
        message,
        stage: AuthStage.oauthMissing,
        oauthReady: false,
      );
      return AuthResult.failure('oauth_required', message);
    }

    state = state.copyWith(
      stage: AuthStage.credentialSubmitting,
      clearError: true,
      clearFailure: true,
      oauthReady: true,
    );
    writePersistedAuthError(null);

    try {
      final session = await ref
          .read(authRepositoryProvider)
          .login(user, password)
          .timeout(const Duration(seconds: 12));
      _log('signIn success user="${session.username}"');
      ref.read(authControllerProvider.notifier).setSession(session);
      state = state.copyWith(
        stage: AuthStage.success,
        oauthReady: true,
        clearError: true,
        clearFailure: true,
      );
      writePersistedAuthError(null);
      return AuthResult.success(session);
    } on TimeoutException {
      _log('signIn timeout');
      const message = 'Login request timed out. Check network/CORS and retry.';
      _setFailure('timeout', message, stage: AuthStage.error, oauthReady: true);
      return AuthResult.failure('timeout', message);
    } catch (error) {
      _log('signIn error=$error');
      final message = _normalizeError(error);
      _setFailure(
        'login_failed',
        message,
        stage: AuthStage.error,
        oauthReady: true,
      );
      return AuthResult.failure('login_failed', message);
    }
  }

  void clearError() {
    state = state.copyWith(
      clearError: true,
      clearFailure: true,
      stage: AuthStage.idle,
    );
    writePersistedAuthError(null);
  }

  void _setFailure(
    String code,
    String message, {
    required AuthStage stage,
    bool? oauthReady,
  }) {
    final normalized = message.trim().isEmpty
        ? 'Login failed for unknown reason.'
        : message;
    _log(
      'failure code=$code stage=$stage oauthReady=${oauthReady ?? state.oauthReady} message="$normalized"',
    );
    final failure = AuthFailure(code: code, message: normalized);
    state = state.copyWith(
      stage: stage,
      oauthReady: oauthReady ?? state.oauthReady,
      errorMessage: normalized,
      lastFailure: failure,
    );
    writePersistedAuthError(normalized);
  }

  String _normalizeError(Object error) {
    final value = error.toString().replaceFirst('Exception: ', '').trim();
    if (value.isEmpty) {
      return 'Login failed for unknown reason (${error.runtimeType}).';
    }
    return value;
  }
}

class AppThemeModeController extends Notifier<ThemeMode> {
  bool _initialized = false;

  @override
  ThemeMode build() {
    return ThemeMode.dark;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final stored = await ref.read(authTokenStoreProvider).readThemeMode();
    if (stored == 'light') {
      state = ThemeMode.light;
    } else {
      state = ThemeMode.dark;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await ref.read(authTokenStoreProvider).writeThemeMode(mode.name);
  }
}
