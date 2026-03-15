import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../providers.dart';
import 'oauth_launcher.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, this.initialError});

  final String? initialError;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(authUiStateProvider.notifier)
          .initialize(initialError: widget.initialError);
    });
  }

  @override
  void didUpdateWidget(covariant LoginPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.initialError;
    if (incoming != null &&
        incoming.trim().isNotEmpty &&
        incoming != oldWidget.initialError) {
      ref.read(authUiStateProvider.notifier).initialize(initialError: incoming);
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    debugPrint('[AUTH] UI login pressed');
    await ref
        .read(authUiStateProvider.notifier)
        .signIn(username: _username.text, password: _password.text);
  }

  Future<void> _startGoogleOauth() async {
    debugPrint('[AUTH] UI oauth button pressed (isWeb=$kIsWeb)');
    try {
      if (kIsWeb) {
        final oauthUrl = AppConfig.oauthSignInUrl(
          redirectTarget: '${AppConfig.backendUrl}/api/auth/status',
        );
        final launched = await launchOauthInSeparateContext(oauthUrl);
        if (!launched) {
          debugPrint('[AUTH] web oauth launch failed');
          ref
              .read(authUiStateProvider.notifier)
              .initialize(initialError: 'Could not open Google OAuth flow.');
          return;
        }
        debugPrint('[AUTH] web oauth launched, probing oauth status');
        await ref.read(authUiStateProvider.notifier).checkOauth();
        return;
      }

      final oauthUrl = AppConfig.oauthSignInUrl(
        redirectTarget: AppConfig.mobileOauthBridgeUrl(),
      );
      final exchangeCode = await launchOauthWithAppCallback(
        oauthUrl,
        AppConfig.oauthCallbackScheme,
      );
      debugPrint(
        '[AUTH] mobile oauth callback accepted, exchange code received',
      );
      await ref
          .read(authUiStateProvider.notifier)
          .completeMobileOauth(exchangeCode);
    } catch (error) {
      debugPrint('[AUTH] oauth flow failed error=$error');
      ref
          .read(authUiStateProvider.notifier)
          .initialize(initialError: 'Google OAuth failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(authUiStateProvider);
    final shownError = uiState.errorMessage ?? '';
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final topColor = isDark ? const Color(0xFF08111D) : const Color(0xFFEEF4EA);
    final bottomColor = isDark
        ? const Color(0xFF122033)
        : const Color(0xFFF7F8F5);
    final helperColor = colorScheme.onSurfaceVariant;
    final errorBackground = isDark
        ? const Color(0xFF3A1619)
        : const Color(0xFFFFEBEE);
    final errorBorder = isDark
        ? const Color(0xFFE57373)
        : const Color(0xFFE53935);
    final errorText = isDark
        ? const Color(0xFFFFCDD2)
        : const Color(0xFFB71C1C);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [topColor, bottomColor],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Blue Mobile',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppConfig.authModeDescription,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: helperColor,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.tonalIcon(
                        onPressed: _startGoogleOauth,
                        icon: const Icon(Icons.login),
                        label: const Text('1) Continue with Google'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: (!kIsWeb || uiState.isCheckingOauth)
                            ? null
                            : () => ref
                                  .read(authUiStateProvider.notifier)
                                  .checkOauth(),
                        icon: uiState.isCheckingOauth
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                uiState.oauthReady
                                    ? Icons.verified_user
                                    : Icons.verified_user_outlined,
                              ),
                        label: Text(
                          uiState.oauthReady
                              ? '2) OAuth ready'
                              : (kIsWeb
                                    ? '2) Check OAuth session'
                                    : '2) Await OAuth callback'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _username,
                        enabled: uiState.oauthReady,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        enabled: uiState.oauthReady,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                        ),
                      ),
                      if (shownError.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: errorBackground,
                            border: Border.all(color: errorBorder),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            shownError,
                            style: TextStyle(
                              color: errorText,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: (uiState.isSubmitting || !uiState.oauthReady)
                            ? null
                            : _login,
                        child: uiState.isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
