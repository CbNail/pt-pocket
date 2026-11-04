import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/notify_settings.dart';
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

// ---------------------------------------------------------------- 个人数据

/// 个人 PT 数据（历程 / 统计），按启用站点聚合（需求 2）。
final FutureProvider<PtDataSnapshot> profileDataProvider = FutureProvider<PtDataSnapshot>((Ref ref) {
  final List<String> siteIds =
      (ref.watch(siteListProvider).valueOrNull ?? const <dynamic>[])
          .where((dynamic s) => s.enabled == true)
          .map((dynamic s) => s.id as String)
          .toList(growable: false);
  return ref.watch(profileApiProvider).fetch(siteIds: siteIds);
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

/// 站点数据刷新控制器：顶部「刷新」刷新全部，卡片内可单独刷新某站。
///
/// 刷新后统一失效 [profileDataProvider]——站点页与「我的数据」共用同一份数据口径。
final NotifierProvider<SiteRefreshController, SiteRefreshView> siteRefreshControllerProvider =
    NotifierProvider<SiteRefreshController, SiteRefreshView>(SiteRefreshController.new);

class SiteRefreshController extends Notifier<SiteRefreshView> {
  @override
  SiteRefreshView build() => const SiteRefreshView();

  Future<void> refreshAll() async {
    state = const SiteRefreshView(refreshingAll: true);
    try {
      final List<String> siteIds =
          (ref.read(siteListProvider).valueOrNull ?? const <dynamic>[])
              .where((dynamic s) => s.enabled == true)
              .map((dynamic s) => s.id as String)
              .toList(growable: false);
      await ref.read(siteStatsApiProvider).refreshAll(siteIds: siteIds);
      state = const SiteRefreshView();
      ref.invalidate(profileDataProvider);
    } on ApiException catch (error) {
      state = SiteRefreshView(error: error.message);
    }
  }

  Future<void> refreshSite(String siteId) async {
    state = SiteRefreshView(refreshingSiteId: siteId);
    try {
      await ref.read(siteStatsApiProvider).refreshSite(siteId);
      state = const SiteRefreshView();
      ref.invalidate(profileDataProvider);
    } on ApiException catch (error) {
      state = SiteRefreshView(error: error.message);
    }
  }
}

// ---------------------------------------------------------------- 监护室

/// 监护事件流（需求 6）。
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
        (ref.read(siteListProvider).valueOrNull ?? const <dynamic>[])
            .where((dynamic s) => s.enabled == true)
            .map((dynamic s) => s.id as String)
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