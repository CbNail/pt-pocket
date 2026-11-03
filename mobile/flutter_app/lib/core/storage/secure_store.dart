import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/app_config.dart';

/// 本机安全存储：站点凭据 / 下载器账号 / NAS 会话令牌。
///
/// 约束（规格书 §2.5 / §10.1）：
/// - 站点 Key、下载器用户名密码、NAS 会话令牌只存在手机安全存储；
/// - 不把 Vaultwarden 主密码写入本存储，也不提交给 NAS；
/// - 设备安全存储不可用时，调用方应降级为「未配置」而不是明文落盘。
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  static const String _ns = AppConfig.secureKeyPrefix;

  String _k(String key) => '$_ns$key';

  Future<String?> read(String key) => _storage.read(key: _k(key));

  Future<void> write(String key, String value) => _storage.write(key: _k(key), value: value);

  Future<void> delete(String key) => _storage.delete(key: _k(key));

  Future<Map<String, dynamic>?> readJson(String key) async {
    final String? raw = await read(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> writeJson(String key, Map<String, dynamic> value) =>
      write(key, jsonEncode(value));

  /// 仅清理本应用命名空间下的凭据，不影响其他应用的 Keychain/Keystore 条目。
  Future<void> clearNamespace() async {
    final Map<String, String> all = await _storage.readAll();
    for (final String k in all.keys) {
      if (k.startsWith(_ns)) {
        await _storage.delete(key: k);
      }
    }
  }
}