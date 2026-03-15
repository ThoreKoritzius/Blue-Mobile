import 'auth_error_storage_stub.dart'
    if (dart.library.html) 'auth_error_storage_web.dart'
    as impl;

const _authErrorStorageKey = 'blue_auth_error';

String? readPersistedAuthError() {
  return impl.readAuthError(_authErrorStorageKey);
}

void writePersistedAuthError(String? value) {
  impl.writeAuthError(_authErrorStorageKey, value);
}
