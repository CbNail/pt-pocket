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

  static const int storageVersion = 1;

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
        'downloaders': downloaders.map((DownloaderConfig d) => d.toJson()).toList(growable: false),
      });

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