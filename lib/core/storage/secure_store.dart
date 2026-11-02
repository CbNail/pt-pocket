import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 敏感凭据统一存取（落在系统级加密存储，不进普通文件）
class SecureStore {
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // Guardian（双链路）
  static const guardianLanUrl = 'guardian.lan.url';
  static const guardianWanUrl = 'guardian.wan.url';
  static const guardianMode = 'guardian.mode'; // auto | lan | wan
  static const guardianUrl = 'guardian.url';   // v0.3 旧字段，仅迁移用
  static const guardianToken = 'guardian.token';

  static Future<String?> read(String key) => _s.read(key: key);
  static Future<void> write(String key, String? value) =>
      _s.write(key: key, value: value);
  static Future<void> delete(String key) => _s.delete(key: key);
}
