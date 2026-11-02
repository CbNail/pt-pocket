import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 敏感凭据统一存取（落在系统级加密存储，不进普通文件）
class SecureStore {
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const guardianUrl = 'guardian.url';
  static const guardianToken = 'guardian.token';

  static Future<String?> read(String key) => _s.read(key: key);
  static Future<void> write(String key, String? value) =>
      _s.write(key: key, value: value);
  static Future<void> delete(String key) => _s.delete(key: key);
}
