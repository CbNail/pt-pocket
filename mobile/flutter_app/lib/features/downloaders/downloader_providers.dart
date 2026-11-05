import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/direct/direct_providers.dart';
import '../../core/direct/downloader_speed_history.dart';
import '../../core/direct/downloader_gateway.dart';
import '../../core/direct/qbittorrent_client.dart';
import '../../core/models/downloader.dart';
import '../../core/providers.dart';
import '../../core/services/downloader_api.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/storage/downloader_repository.dart';

/// 下载器连接测试复用统一的地址可达性探测（只探测地址，不校验账号）。
typedef DownloaderReachabilityProbe = SiteReachabilityProbe;

/// 下载器仓库。
final Provider<DownloaderRepository> downloaderRepositoryProvider =
    Provider<DownloaderRepository>(
  (Ref ref) => DownloaderRepository(
    prefs: ref.watch(prefsStoreProvider),
    secure: ref.watch(secureStoreProvider),
  ),
);

/// 下载器接口（走 NAS 后端版本化 API）。
final Provider<DownloaderApi> downloaderApiProvider = Provider<DownloaderApi>(
  (Ref ref) => DownloaderApi(client: ref.watch(apiClientProvider)),
);

/// 下载器地址探测（连接测试）。
final Provider<DownloaderReachabilityProbe> downloaderProbeProvider =
    Provider<DownloaderReachabilityProbe>(
  (Ref ref) => DownloaderReachabilityProbe(dio: ref.watch(proxyRuntimeProvider).createDio()),
);

/// 下载器清单状态。
final AsyncNotifierProvider<DownloaderListNotifier, List<DownloaderConfig>> downloaderListProvider =
    AsyncNotifierProvider<DownloaderListNotifier, List<DownloaderConfig>>(
  DownloaderListNotifier.new,
);

class DownloaderListNotifier extends AsyncNotifier<List<DownloaderConfig>> {
  DownloaderRepository get _repo => ref.read(downloaderRepositoryProvider);

  @override
  Future<List<DownloaderConfig>> build() async => _repo.loadAll();

  void _reload() => state = AsyncData<List<DownloaderConfig>>(_repo.loadAll());

  Future<DownloaderConfig> upsert(DownloaderConfig config) async {
    final DownloaderConfig stored = await _repo.upsert(config);
    _reload();
    return stored;
  }

  Future<void> remove(String downloaderId) async {
    await _repo.remove(downloaderId);
    _reload();
  }

  Future<void> saveCredential(String downloaderId, Map<String, dynamic> credential) async {
    await _repo.saveCredential(downloaderId, credential);
    final List<DownloaderConfig> list = _repo.loadAll();
    await _repo.saveAll(
      list
          .map((DownloaderConfig d) => d.id == downloaderId
              ? d.copyWith(
                  credentialConfigured: true,
                  health: DownloaderHealth.unknown,
                  updatedAt: DateTime.now(),
                )
              : d)
          .toList(growable: false),
    );
    _reload();
  }

  Future<void> clearCredential(String downloaderId) async {
    await _repo.deleteCredential(downloaderId);
    final List<DownloaderConfig> list = _repo.loadAll();
    await _repo.saveAll(
      list
          .map((DownloaderConfig d) => d.id == downloaderId
              ? d.copyWith(credentialConfigured: false, updatedAt: DateTime.now())
              : d)
          .toList(growable: false),
    );
    _reload();
  }

  Future<void> recordProbe(String downloaderId, bool reachable) async {
    final List<DownloaderConfig> list = _repo.loadAll();
    await _repo.saveAll(
      list
          .map((DownloaderConfig d) => d.id == downloaderId
              ? d.copyWith(
                  health: reachable ? DownloaderHealth.ok : DownloaderHealth.danger,
                  lastTestedAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                )
              : d)
          .toList(growable: false),
    );
    _reload();
  }

  /// 标记默认下载器（同一时刻只有一个）。
  Future<void> setDefault(String downloaderId) async {
    await _repo.setDefault(downloaderId);
    _reload();
  }

  Future<void> toggleEnabled(String downloaderId) async {
    final List<DownloaderConfig> list = _repo.loadAll();
    await _repo.saveAll(
      list
          .map((DownloaderConfig d) => d.id == downloaderId ? d.copyWith(enabled: !d.enabled) : d)
          .toList(growable: false),
    );
    _reload();
  }
}

/// 按 id 取单个下载器。
final ProviderFamily<DownloaderConfig?, String> downloaderByIdProvider =
    Provider.family<DownloaderConfig?, String>((Ref ref, String downloaderId) {
  final List<DownloaderConfig> list =
      ref.watch(downloaderListProvider).valueOrNull ?? const <DownloaderConfig>[];
  for (final DownloaderConfig config in list) {
    if (config.id == downloaderId) return config;
  }
  return null;
});

/// 当前默认下载器（推送时未指定目标就走它）。
final Provider<DownloaderConfig?> defaultDownloaderProvider = Provider<DownloaderConfig?>(
  (Ref ref) {
    final List<DownloaderConfig> list =
        ref.watch(downloaderListProvider).valueOrNull ?? const <DownloaderConfig>[];
    for (final DownloaderConfig config in list) {
      if (config.isDefault) return config;
    }
    return list.isEmpty ? null : list.first;
  },
);

/// 下载器数据通道：qBittorrent 直连 WebUI（`/api/v2`）为主，NAS 后端可用时补充。
final Provider<DownloaderGateway> downloaderGatewayProvider = Provider<DownloaderGateway>(
  (Ref ref) => DownloaderGateway(
    () => ref.read(endpointProfileProvider).isConfigured,
    (String downloaderId) => ref.read(downloaderByIdProvider(downloaderId)),
    (String downloaderId) =>
        ref.read(downloaderRepositoryProvider).readCredential(downloaderId),
    nas: ref.watch(downloaderApiProvider),
    qb: ref.watch(qbittorrentClientProvider),
    tr: ref.watch(transmissionClientProvider),
  ),
);

/// 某个下载器的任务列表（qBittorrent 直连 / 后端转发）。
final FutureProviderFamily<List<DownloaderTask>, String> downloaderTasksProvider =
    FutureProvider.family<List<DownloaderTask>, String>(
  (Ref ref, String downloaderId) =>
      ref.watch(downloaderGatewayProvider).fetchTasks(downloaderId),
);

/// 某个下载器的可选分类 / 标签 / 路径（供任务批量操作的选择器）。
final FutureProviderFamily<DownloaderTaskOption, String> downloaderTaskOptionsProvider =
    FutureProvider.family<DownloaderTaskOption, String>(
  (Ref ref, String downloaderId) =>
      ref.watch(downloaderGatewayProvider).fetchTaskOptions(downloaderId),
);

/// 单个下载器的聚合统计（列表卡片与网格图共用同一份口径）。
///
/// 每次成功取到就顺手记一次速率采样，供网格图的速率曲线使用；采样只在内存里，
/// 不落盘、不做长期统计。
final FutureProviderFamily<DownloaderStats, String> downloaderStatsProvider =
    FutureProvider.family<DownloaderStats, String>((Ref ref, String downloaderId) async {
  final DownloaderStats stats =
      await ref.watch(downloaderGatewayProvider).fetchStats(downloaderId);
  if (stats.sampled) {
    ref
        .read(downloaderSpeedHistoryProvider)
        .record(downloaderId, stats.downloadSpeed, stats.uploadSpeed);
  }
  return stats;
});

/// 下载器全局传输状态（qBittorrent 直连时可用；任务页头部的速度条）。
final FutureProviderFamily<QbTransferInfo?, String> downloaderTransferProvider =
    FutureProvider.family<QbTransferInfo?, String>(
  (Ref ref, String downloaderId) =>
      ref.watch(downloaderGatewayProvider).fetchTransferInfo(downloaderId),
);

/// 下载器凭据（异步读取安全存储）。
final FutureProviderFamily<Map<String, dynamic>?, String> downloaderCredentialProvider =
    FutureProvider.family<Map<String, dynamic>?, String>(
  (Ref ref, String downloaderId) =>
      ref.watch(downloaderRepositoryProvider).readCredential(downloaderId),
);