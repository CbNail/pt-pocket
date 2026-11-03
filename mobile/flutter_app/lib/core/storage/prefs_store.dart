import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// 非敏感本地偏好存储（统一命名空间 + JSON 读写 + 变更通知预留）。
///
/// 只存放非机密配置：链路设置、主题、导入导出时间戳、配置基线等。
/// 站点凭据 / 令牌 / 下载器账号一律走 [SecureStore]。
class PrefsStore {
  PrefsStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _ns = AppConfig.prefsKeyPrefix;

  String _k(String key) => '$_ns$key';

  bool contains(String key) => _prefs.containsKey(_k(key));

  String? getString(String key) => _prefs.getString(_k(key));

  Future<void> setString(String key, String value) => _prefs.setString(_k(key), value);

  int? getInt(String key) => _prefs.getInt(_k(key));

  Future<void> setInt(String key, int value) => _prefs.setInt(_k(key), value);

  bool? getBool(String key) => _prefs.getBool(_k(key));

  Future<void> setBool(String key, bool value) => _prefs.setBool(_k(key), value);

  double? getDouble(String key) => _prefs.getDouble(_k(key));

  Future<void> setDouble(String key, double value) => _prefs.setDouble(_k(key), value);

  List<String>? getStringList(String key) => _prefs.getStringList(_k(key));

  Future<void> setStringList(String key, List<String> value) =>
      _prefs.setStringList(_k(key), value);

  /// 读取 JSON 对象；解析失败时返回 null 而不抛异常，避免坏数据阻塞启动。
  Map<String, dynamic>? getJson(String key) {
    final String? raw = _prefs.getString(_k(key));
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> setJson(String key, Map<String, dynamic> value) =>
      _prefs.setString(_k(key), jsonEncode(value));

  Future<void> remove(String key) => _prefs.remove(_k(key));

  /// 当前命名空间下的所有键（去除前缀）。
  Set<String> namespacedKeys() => _prefs
      .getKeys()
      .where((String k) => k.startsWith(_ns))
      .map((String k) => k.substring(_ns.length))
      .toSet();
}