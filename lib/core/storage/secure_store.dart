import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 敏感凭据统一存取（落在系统级加密存储，不进普通文件）
class SecureStore {
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // Guardian（双链路）
  static const guardianLanUrl = 'guardian.lan.url';
  static const guardianWanUrl = 'guardian.wan.url';
  static const guardianMode = 'guardian.mode';
  static const guardianUrl = 'guardian.url';
  static const guardianToken = 'guardian.token';

  // qBittorrent（双链路）
  static const qbLanUrl = 'qb.lan.url';
  static const qbWanUrl = 'qb.wan.url';
  static const qbMode = 'qb.mode';
  static const qbName = 'qb.name';
  static const qbUsername = 'qb.username';
  static const qbPassword = 'qb.password';
  static const qbPath = 'qb.path';

  // Transmission（双链路）
  static const trLanUrl = 'tr.lan.url';
  static const trWanUrl = 'tr.wan.url';
  static const trMode = 'tr.mode';
  static const trName = 'tr.name';
  static const trUsername = 'tr.username';
  static const trPassword = 'tr.password';
  static const trPath = 'tr.path';

  // 收藏的种子 ID（逗号分隔）
  static const favIds = 'mteam.favids';

  static Future<String?> read(String key) => _s.read(key: key);
  static Future<void> write(String key, String? value) =>
      _s.write(key: key, value: value);
  static Future<void> delete(String key) => _s.delete(key: key);
}
