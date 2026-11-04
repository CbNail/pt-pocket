import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/direct/direct_providers.dart';
import '../../core/direct/site_stats_service.dart';
import '../../core/direct/stats_history_store.dart';
import '../../core/models/notify_settings.dart';
import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/services/status_api.dart';
import '../../core/storage/app_keys.dart';
import '../../core/storage/major_site_repository.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/storage/secure_store.dart';
import '../sites/site_providers.dart';

// ---------------------------------------------------------------- 接口

/// NAS 后端接口（保留：本地直连取不到的站点可由后端补齐）。
final Provider<ProfileApi> profileApiProvider =
    Provider<ProfileApi>((Ref ref) => ProfileApi(client: ref.watch(apiClientProvider)));

final Provider<SiteStatsApi> siteStatsApiProvider =
    Provider<SiteStatsApi>((Ref ref) => SiteStatsApi(client: ref.watch(apiClientProvider)));

final Provider<MonitorApi> monitorApiProvider =
    Provider<MonitorApi>((Ref ref) => MonitorApi(client: ref.watch(apiClientProvider)));

final Provider<SignInApi> signInApiProvider =
    Provider<SignInApi>((Ref ref) => SignInApi(client: ref.watch(apiClientProvider)));

final Provider<NotifyApi> notifyApiProvider =
    Provider<NotifyApi>((Ref ref) => NotifyApi(client: ref.watch(apiClientProvider)));

// ---------------------------------------------------------------- 单站数据（直连优先）

/// 站点数据组装服务：直连用户页 + 本地历史 + 等级规则。
final Provider<SiteStatsService> siteStatsServiceProvider = Provider<SiteStatsService>(
  (Ref ref) => SiteStatsService(
    client: ref.watch(nexusPhpClientProvider),
    history: ref.watch(statsHistoryStoreProvider),
  ),
);

/// 单站数据：App 直连站点用户页采集。
///
/// 回退顺序：本地直连 → （配置了 NAS 时）后端 `/api/v1/profile`。
/// 失败时返回带具体原因的 [SiteStats]（缺凭据 / 登录态失效 / 被限流 / 网络不可达），
/// 而不是把整页数据变成「内网与外网地址均不可用」这类与服务地址无关的报错。
final FutureProviderFamily<SiteStats, String> siteStatsProvider =
    FutureProvider.family<SiteStats, String>((Ref ref, String siteId) async {
  final PtSite? site = ref.watch(siteByIdProvider(siteId));
  if (site == null) {
    return SiteStats(
      siteId: siteId,
      siteName: '',
      refreshState: SiteRefreshState.failed,
      refreshMessage: '站点已不存在（$siteId），请刷新站点列表',
      signInKnown: false,
    );
  }

  final Map<String, dynamic>? credential = await ref.watch(siteCredentialProvider(siteId).future);
  final SiteStatsService service = ref.watch(siteStatsServiceProvider);
  final SiteStats stats = await service.fetchSite(site, credential: credential);
  if (stats.refreshState == SiteRefreshState.refreshed) return stats;

  // 本地取不到（缺凭据 / 网络 / 限流）：配置了 NAS 后端就让后端再试一次。
  final bool localProblem = stats.refreshState == SiteRefreshState.notLoggedIn ||
      stats.refreshState == SiteRefreshState.failed;
  if (localProblem && ref.watch(endpointProfileProvider).isConfigured) {
    try {
      final PtDataSnapshot snapshot =
          await ref.read(profileApiProvider).fetch(siteIds: <String>[siteId]);
      for (final SiteStats item in snapshot.sites) {
        if (item.siteId == siteId) return item;
      }
    } catch (_) {
      // 后端也不可用：保留直连给出的、更贴近本地实际的原因。
    }
  }
  return stats;
});

// ---------------------------------------------------------------- 个人数据

/// 启用站点清单（首次进入时等待一次清单加载）。
Future<List<PtSite>> _enabledSites(Ref ref) async {
  List<PtSite> sites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];
  if (sites.isEmpty) {
    try {
      sites = await ref.watch(siteListProvider.future);
    } catch (_) {
      sites = const <PtSite>[];
    }
  }
  return sites.where((PtSite s) => s.enabled).toList(growable: false);
}

/// 个人 PT 数据（我的数据 / 数据统计 / 养老进度），按启用站点聚合。
///
/// 数据来自 [siteStatsProvider]（直连各站点用户页），因此「我的数据」「养老进度」
/// 不再依赖尚未实现的 NAS 后端即可用；本地历史提供今日增量与时间轴。
final FutureProvider<PtDataSnapshot> profileDataProvider = FutureProvider<PtDataSnapshot>(
  (Ref ref) async {
    final List<PtSite> sites = await _enabledSites(ref);
    if (sites.isEmpty) return const PtDataSnapshot(sites: <SiteStats>[]);

    final List<SiteStats> stats = await Future.wait(
      sites.map((PtSite site) => ref.watch(siteStatsProvider(site.id).future)),
    );

    final List<SiteStats> withBaseline =
        stats.where((SiteStats s) => s.todayBaselineAvailable).toList(growable: false);
    final int failed = stats
        .where((SiteStats s) =>
            s.refreshState == SiteRefreshState.failed ||
            s.refreshState == SiteRefreshState.notLoggedIn)
        .length;
    final bool allBaseline = withBaseline.length == stats.length && stats.isNotEmpty;

    final List<String> notes = <String>[
      '数据由 App 直连各站点用户页采集，并在本机保存每日采样（用于今日增量与综合时魔估算）',
      if (failed > 0) '$failed 个站点本次未取到数据，卡片上有具体原因',
      if (!allBaseline) '今日增量只统计已有前一自然日基线的站点，其余显示「基线不足」',
    ];

    return PtDataSnapshot(
      sites: stats,
      generatedAt: DateTime.now(),
      notice: notes.join('；'),
      todayUploadedBytes: withBaseline.isEmpty
          ? null
          : withBaseline.fold<int>(0, (int sum, SiteStats s) => sum + s.todayUploadedBytes),
      todayDownloadedBytes: withBaseline.isEmpty
          ? null
          : withBaseline.fold<int>(0, (int sum, SiteStats s) => sum + s.todayDownloadedBytes),
      todayBaselineAvailable: allBaseline,
    );
  },
);

/// 单站时间轴（近 30 天有采样的自然日）；数据刷新后自动重算。
final ProviderFamily<List<TrendPoint>, String> siteTrendProvider =
    Provider.family<List<TrendPoint>, String>((Ref ref, String siteId) {
  ref.watch(profileDataProvider);
  return ref.watch(statsHistoryStoreProvider).trend(siteId, days: 30);
});

// ---------------------------------------------------------------- 站点数据刷新

/// 站点数据刷新的进行状态。
class SiteRefreshView {
  const SiteRefreshView({this.refreshingSiteId, this.refreshingAll = false, this.error});

  /// 正在刷新的单个站点 id（null 表示没有单站刷新在进行）。
  final String? refreshingSiteId;
  final bool refreshingAll;

  /// 最近一次刷新的失败原因。
  final String? error;

  bool get busy => refreshingAll || refreshingSiteId != null;
}

/// 站点数据刷新控制器：刷新 = 重新直连站点用户页（并让 NAS 后端也刷一次，若已配置）。
///
/// 刷新后统一失效 [profileDataProvider]——站点页与「我的数据」「养老进度」共用同一份数据。
final NotifierProvider<SiteRefreshController, SiteRefreshView> siteRefreshControllerProvider =
    NotifierProvider<SiteRefreshController, SiteRefreshView>(SiteRefreshController.new);

class SiteRefreshController extends Notifier<SiteRefreshView> {
  @override
  SiteRefreshView build() => const SiteRefreshView();

  bool get _nasConfigured => ref.read(endpointProfileProvider).isConfigured;

  List<String> _enabledIds() =>
      (ref.read(siteListProvider).valueOrNull ?? const <PtSite>[])
          .where((PtSite s) => s.enabled)
          .map((PtSite s) => s.id)
          .toList(growable: false);

  Future<void> refreshAll() async {
    state = const SiteRefreshView(refreshingAll: true);
    final List<String> ids = _enabledIds();
    if (_nasConfigured) {
      try {
        await ref.read(siteStatsApiProvider).refreshAll(siteIds: ids);
      } on ApiException {
        // 后端不可用时不影响直连刷新。
      }
    }
    try {
      ref.invalidate(siteStatsProvider);
      await ref.read(profileDataProvider.future);
      state = const SiteRefreshView();
    } catch (error) {
      state = SiteRefreshView(error: '$error');
    }
  }

  Future<void> refreshSite(String siteId) async {
    state = SiteRefreshView(refreshingSiteId: siteId);
    if (_nasConfigured) {
      try {
        await ref.read(siteStatsApiProvider).refreshSite(siteId);
      } on ApiException {
        // 同上：后端失败不阻塞直连刷新。
      }
    }
    try {
      ref.invalidate(siteStatsProvider(siteId));
      await ref.read(siteStatsProvider(siteId).future);
      ref.invalidate(profileDataProvider);
      state = const SiteRefreshView();
    } catch (error) {
      state = SiteRefreshView(error: '$error');
    }
  }
}

// ---------------------------------------------------------------- 监护室（NAS 巡检，可选）

/// NAS 后端的监护事件流（后端已部署时作为补充来源；监护室主数据来自公开状态页）。
final FutureProvider<List<MonitorEvent>> monitorEventsProvider =
    FutureProvider<List<MonitorEvent>>((Ref ref) {
  return ref.watch(monitorApiProvider).fetchEvents();
});

// ---------------------------------------------------------------- 签到

/// 最近签到记录。
final FutureProvider<List<SignInRecord>> signInRecordsProvider =
    FutureProvider<List<SignInRecord>>((Ref ref) {
  return ref.watch(signInApiProvider).fetchRecords();
});

/// 自动补签配置（需求 10：未成功签到的站点自动定时补签）。
class SignInAutoConfig {
  const SignInAutoConfig({this.enabled = false, this.hour = 8, this.minute = 0});

  final bool enabled;
  final int hour;
  final int minute;

  String get label =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  SignInAutoConfig copyWith({bool? enabled, int? hour, int? minute}) => SignInAutoConfig(
        enabled: enabled ?? this.enabled,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
      );
}

final NotifierProvider<SignInAutoNotifier, SignInAutoConfig> signInAutoProvider =
    NotifierProvider<SignInAutoNotifier, SignInAutoConfig>(SignInAutoNotifier.new);

class SignInAutoNotifier extends Notifier<SignInAutoConfig> {
  PrefsStore get _prefs => ref.read(prefsStoreProvider);

  @override
  SignInAutoConfig build() => SignInAutoConfig(
        enabled: _prefs.getBool(PrefKeys.signInAutoEnabled) ?? false,
        hour: _prefs.getInt(PrefKeys.signInAutoHour) ?? 8,
        minute: _prefs.getInt(PrefKeys.signInAutoMinute) ?? 0,
      );

  Future<void> update(SignInAutoConfig config) async {
    await _prefs.setBool(PrefKeys.signInAutoEnabled, config.enabled);
    await _prefs.setInt(PrefKeys.signInAutoHour, config.hour);
    await _prefs.setInt(PrefKeys.signInAutoMinute, config.minute);
    state = config;
  }
}

/// 签到执行状态。
class SignInState {
  const SignInState({this.running = false, this.lastResult, this.error});

  final bool running;
  final SignInRunResult? lastResult;
  final String? error;

  SignInState copyWith({
    bool? running,
    SignInRunResult? lastResult,
    String? error,
    bool clearError = false,
  }) =>
      SignInState(
        running: running ?? this.running,
        lastResult: lastResult ?? this.lastResult,
        error: clearError ? null : (error ?? this.error),
      );
}

final NotifierProvider<SignInController, SignInState> signInControllerProvider =
    NotifierProvider<SignInController, SignInState>(SignInController.new);

class SignInController extends Notifier<SignInState> {
  @override
  SignInState build() => const SignInState();

  /// 一键签到：对启用站点批量下发。[mode] 见 [SignInMode]。
  Future<void> runAll({SignInMode mode = SignInMode.both}) async {
    final List<String> siteIds =
        (ref.read(siteListProvider).valueOrNull ?? const <PtSite>[])
            .where((PtSite s) => s.enabled)
            .map((PtSite s) => s.id)
            .toList(growable: false);
    await _run(() => ref.read(signInApiProvider).runAll(siteIds: siteIds, mode: mode));
  }

  /// 单站补签。
  Future<void> runSite(String siteId, {SignInMode mode = SignInMode.both}) =>
      _run(() => ref.read(signInApiProvider).runSite(siteId, mode: mode));

  Future<void> _run(Future<SignInRunResult> Function() action) async {
    state = state.copyWith(running: true, clearError: true);
    try {
      final SignInRunResult result = await action();
      state = SignInState(running: false, lastResult: result);
      ref.invalidate(signInRecordsProvider);
      ref.invalidate(profileDataProvider);
    } on ApiException catch (error) {
      state = state.copyWith(running: false, error: error.message);
    } catch (error) {
      state = state.copyWith(running: false, error: '$error（签到需要 NAS 后端下发）');
    }
  }
}

// ---------------------------------------------------------------- 12 大站点

final Provider<MajorSiteRepository> majorSiteRepositoryProvider = Provider<MajorSiteRepository>(
  (Ref ref) => MajorSiteRepository(prefs: ref.watch(prefsStoreProvider)),
);

/// 12 大站点槽位（需求 11）。
final AsyncNotifierProvider<MajorSiteNotifier, List<MajorSiteSlot>> majorSiteSlotsProvider =
    AsyncNotifierProvider<MajorSiteNotifier, List<MajorSiteSlot>>(MajorSiteNotifier.new);

class MajorSiteNotifier extends AsyncNotifier<List<MajorSiteSlot>> {
  MajorSiteRepository get _repo => ref.read(majorSiteRepositoryProvider);

  @override
  Future<List<MajorSiteSlot>> build() async => _repo.loadAll();

  Future<void> upsert(MajorSiteSlot slot) async {
    await _repo.upsert(slot);
    state = AsyncData<List<MajorSiteSlot>>(_repo.loadAll());
  }

  /// 已配置槽位数与总槽位。
  (int configured, int total) get counts {
    final List<MajorSiteSlot> slots = state.valueOrNull ?? const <MajorSiteSlot>[];
    return (_repo.configuredCount(slots), slots.length);
  }
}

// ---------------------------------------------------------------- 推送通道

final NotifierProvider<NotifySettingsNotifier, NotifySettings> notifySettingsProvider =
    NotifierProvider<NotifySettingsNotifier, NotifySettings>(NotifySettingsNotifier.new);

class NotifySettingsNotifier extends Notifier<NotifySettings> {
  PrefsStore get _prefs => ref.read(prefsStoreProvider);

  SecureStore get _secure => ref.read(secureStoreProvider);

  @override
  NotifySettings build() {
    final Map<String, dynamic>? json = _prefs.getJson(PrefKeys.notifySettings);
    return json == null ? const NotifySettings() : NotifySettings.fromJson(json);
  }

  /// 保存设置；[wecomWebhook] / [telegramToken] 传 null 表示不改动已保存的凭据，空串表示清除。
  Future<void> save(
    NotifySettings settings, {
    String? wecomWebhook,
    String? telegramToken,
  }) async {
    NotifySettings next = settings;
    if (wecomWebhook != null) {
      if (wecomWebhook.isEmpty) {
        await _secure.delete(SecureKeys.notifyWecomWebhook);
        next = next.copyWith(wecomWebhookConfigured: false);
      } else {
        await _secure.write(SecureKeys.notifyWecomWebhook, wecomWebhook);
        next = next.copyWith(wecomWebhookConfigured: true);
      }
    }
    if (telegramToken != null) {
      if (telegramToken.isEmpty) {
        await _secure.delete(SecureKeys.notifyTelegramToken);
        next = next.copyWith(telegramTokenConfigured: false);
      } else {
        await _secure.write(SecureKeys.notifyTelegramToken, telegramToken);
        next = next.copyWith(telegramTokenConfigured: true);
      }
    }
    await _prefs.setJson(PrefKeys.notifySettings, next.toJson());
    state = next;
  }
}