import '../models/downloader.dart';
import 'app_keys.dart';
import 'prefs_store.dart';
import 'secure_store.dart';

/// 下载器仓库：配置走非敏感偏好存储，账号密码走本机安全存储。
///
/// 与站点仓库同构：删除下载器时一并清理其凭据，避免留下孤儿密钥。
class DownloaderRepository {
  DownloaderRepository({required this.prefs, required this.secure});

  final PrefsStore prefs;
  final SecureStore secure;

  /// 1 → 2：新增「默认下载器」标记（`isDefault`），旧数据按「第一条为默认」补齐。
  static const int storageVersion = 2;

  List<DownloaderConfig> loadAll() {
    final Map<String, dynamic>? raw = prefs.getJson(PrefKeys.downloaderIndex);
    if (raw == null) return <DownloaderConfig>[];
    final Object? list = raw['downloaders'];
    if (list is! List) return <DownloaderConfig>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(DownloaderConfig.fromJson)
        .where((DownloaderConfig d) => d.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> saveAll(List<DownloaderConfig> downloaders) =>
      prefs.setJson(PrefKeys.downloaderIndex, <String, dynamic>{
        'version': storageVersion,
        'downloaders': normalizeDefault(downloaders)
            .map((DownloaderConfig d) => d.toJson())
            .toList(growable: false),
      });

  /// 收敛「默认下载器」：任何时刻最多一个默认。
  ///
  /// - 列表里已有默认 → 只保留第一个默认，其余清掉（避免历史数据里出现多个默认）；
  /// - 列表非空但一个默认都没有 → 把第一条设为默认（首次添加、删掉默认项后都不会出现
  ///   “有下载器却没有默认”的空档）。
  static List<DownloaderConfig> normalizeDefault(List<DownloaderConfig> downloaders) {
    if (downloaders.isEmpty) return downloaders;
    int keep = downloaders.indexWhere((DownloaderConfig d) => d.isDefault);
    if (keep < 0) keep = 0;
    return <DownloaderConfig>[
      for (int i = 0; i < downloaders.length; i++)
        downloaders[i].isDefault == (i == keep)
            ? downloaders[i]
            : downloaders[i].copyWith(isDefault: i == keep),
    ];
  }

  /// 把指定下载器设为默认，其余一律取消；id 不存在时不做任何改动。
  Future<void> setDefault(String downloaderId) async {
    final List<DownloaderConfig> list = loadAll();
    if (!list.any((DownloaderConfig d) => d.id == downloaderId)) return;
    await saveAll(
      list
          .map((DownloaderConfig d) => d.isDefault == (d.id == downloaderId)
              ? d
              : d.copyWith(isDefault: d.id == downloaderId))
          .toList(growable: false),
    );
  }

  Future<DownloaderConfig> upsert(DownloaderConfig config) async {
    final List<DownloaderConfig> list = loadAll().toList();
    final DateTime now = DateTime.now();
    final DownloaderConfig stored = config.copyWith(
      createdAt: config.createdAt ?? now,
      updatedAt: now,
    );
    final int index = list.indexWhere((DownloaderConfig d) => d.id == config.id);
    if (index >= 0) {
      list[index] = stored;
    } else {
      list.add(stored);
    }
    // 新设的默认要顶掉原来的默认，否则 normalizeDefault 会保留更早那条。
    if (stored.isDefault) {
      for (int i = 0; i < list.length; i++) {
        if (list[i].id != stored.id && list[i].isDefault) {
          list[i] = list[i].copyWith(isDefault: false);
        }
      }
    }
    await saveAll(list);
    return stored;
  }

  Future<void> remove(String downloaderId) async {
    final List<DownloaderConfig> list =
        loadAll().where((DownloaderConfig d) => d.id != downloaderId).toList(growable: false);
    await saveAll(list);
    await deleteCredential(downloaderId);
  }

  Future<void> saveCredential(String downloaderId, Map<String, dynamic> credential) =>
      secure.writeJson(SecureKeys.downloaderCredential(downloaderId), credential);

  Future<Map<String, dynamic>?> readCredential(String downloaderId) =>
      secure.readJson(SecureKeys.downloaderCredential(downloaderId));

  Future<void> deleteCredential(String downloaderId) =>
      secure.delete(SecureKeys.downloaderCredential(downloaderId));

  Future<bool> hasCredential(String downloaderId) async =>
      await readCredential(downloaderId) != null;
}