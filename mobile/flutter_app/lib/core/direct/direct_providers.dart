import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/monitor_dashboard.dart';
import '../providers.dart';
import '../storage/app_keys.dart';
import '../storage/prefs_store.dart';
import 'nexusphp_client.dart';
import 'qbittorrent_client.dart';
import 'savept_monitor_client.dart';
import 'stats_history_store.dart';

/// 直连数据源专用 Dio：复用 App 代理设置与超时基线（与站点探测同一套网络栈）。
final Provider<Dio> directDioProvider = Provider<Dio>(
  (Ref ref) => ref.watch(proxyRuntimeProvider).createDio(),
);

/// 监护室数据源基址（默认 savept.icu，可在偏好里改写）。
final Provider<String> monitorBaseUrlProvider = Provider<String>((Ref ref) {
  final String? custom = ref.watch(prefsStoreProvider).getString(PrefKeys.monitorBaseUrl);
  if (custom != null && custom.trim().isNotEmpty) return custom.trim();
  return SavePtMonitorClient.defaultBaseUrl;
});

/// 监护室直连客户端。
final Provider<SavePtMonitorClient> savePtMonitorClientProvider = Provider<SavePtMonitorClient>(
  (Ref ref) => SavePtMonitorClient(
    ref.watch(proxyRuntimeProvider).createDio(),
    baseUrl: ref.watch(monitorBaseUrlProvider),
  ),
);

/// 站点用户页直连客户端（NexusPHP 结构）。
final Provider<NexusPhpClient> nexusPhpClientProvider = Provider<NexusPhpClient>(
  (Ref ref) => NexusPhpClient(ref.watch(proxyRuntimeProvider).createDio()),
);

/// 本地数据历史（今日增量 / 时魔估算 / 时间轴）。
final Provider<StatsHistoryStore> statsHistoryStoreProvider = Provider<StatsHistoryStore>(
  (Ref ref) => StatsHistoryStore(prefs: ref.watch(prefsStoreProvider)),
);

/// qBittorrent 会话缓存与直连客户端。
final Provider<QbSessionStore> qbSessionStoreProvider =
    Provider<QbSessionStore>((Ref ref) => QbSessionStore());

final Provider<QbittorrentClient> qbittorrentClientProvider = Provider<QbittorrentClient>(
  (Ref ref) => QbittorrentClient(
    ref.watch(proxyRuntimeProvider).createDio(),
    sessions: ref.watch(qbSessionStoreProvider),
  ),
);

/// 监护室快照：直连公开状态页；失败时降级用最近一次成功快照（界面会标注「缓存」）。
///
/// 与参考实现（MoviePilot 的 Vue-PT 监护室插件）一样读公开数据，
/// 因此不需要 NAS 后端就能显示病危 / 站庆 / 死亡 / 恢复公告。
final FutureProvider<MonitorDashboard> monitorDashboardProvider =
    FutureProvider<MonitorDashboard>((Ref ref) async {
  final SavePtMonitorClient client = ref.watch(savePtMonitorClientProvider);
  final PrefsStore prefs = ref.watch(prefsStoreProvider);
  try {
    final MonitorDashboard dashboard = await client.fetchDashboard();
    await prefs.setJson(PrefKeys.monitorCache, dashboard.toJson());
    return dashboard;
  } catch (error) {
    final Map<String, dynamic>? cached = prefs.getJson(PrefKeys.monitorCache);
    if (cached != null) {
      final MonitorDashboard snapshot = MonitorDashboard.fromJson(cached);
      if (!snapshot.isEmpty) {
        return MonitorDashboard(
          sites: snapshot.sites,
          notices: snapshot.notices,
          fetchedAt: snapshot.fetchedAt,
          fromCache: true,
          sourceUrl: snapshot.sourceUrl,
          notice: '实时抓取失败，下面是上次成功抓取的缓存：$error',
        );
      }
    }
    rethrow;
  }
});

/// 监护室历史事件类型（死亡 / 站庆）。
enum MonitorHistoryKind {
  dead('历史死亡'),
  anniversary('历史站庆');

  const MonitorHistoryKind(this.label);

  final String label;
}

/// 监护室历史事件（页面「历史事件」弹窗的数据源）。
final FutureProviderFamily<MonitorHistoryPage, ({MonitorHistoryKind kind, int page})>
    monitorHistoryProvider =
    FutureProvider.family<MonitorHistoryPage, ({MonitorHistoryKind kind, int page})>(
  (Ref ref, ({MonitorHistoryKind kind, int page}) query) {
    final SavePtMonitorClient client = ref.watch(savePtMonitorClientProvider);
    return switch (query.kind) {
      MonitorHistoryKind.dead => client.fetchDeadHistory(page: query.page),
      MonitorHistoryKind.anniversary => client.fetchAnniversaryHistory(page: query.page),
    };
  },
);