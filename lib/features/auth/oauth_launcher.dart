import 'oauth_launcher_stub.dart'
    if (dart.library.html) 'oauth_launcher_web.dart'
    as impl;

Future<bool> launchOauthInSeparateContext(String url) {
  return impl.launchOauth(url);
}

Future<String> launchOauthWithAppCallback(String url, String callbackScheme) {
  return impl.launchOauthWithAppCallback(url, callbackScheme);
}
