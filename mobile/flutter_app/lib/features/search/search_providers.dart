import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/adapters/moviepilot_adapter_registry.dart';
import '../../core/models/moviepilot.dart';
import '../../core/models/pt_site.dart';
import '../../core/models/service_health.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/endpoint_resolver.dart';
import '../../core/providers.dart';
import '../../core/services/search_api.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/storage/app_keys.dart';
import '../../core/storage/favorite_repository.dart';
import '../../core/storage/mp_repository.dart';
import '../../core/storage/prefs_store.dart';
import '../sites/site_providers.dart';

/// MoviePilot 连接测试复用统一的地址可达性探测。
typedef MpReachabilityProbe = SiteReachabilityProbe;

/// MoviePilot API 令牌（异步读取安全存储）。
final FutureProviderFamily<Map<String, dynamic>?, String> mpCredentialProvider =
    FutureProvider.family<Map<String, dynamic>?, String>(
  (Ref ref, String instanceId) => ref.watch(mpRepositoryProvider).readCredential(instanceId),
);

/// 聚合搜索接口（走 NAS 后端）。
final Provider<SearchApi> searchApiProvider =
    Provider<SearchApi>((Ref ref) => SearchApi(client: ref.watch(apiClientProvider)));

/// 收藏仓库（本地）。
final Provider<FavoriteRepository> favoriteRepositoryProvider = Provider<FavoriteRepository>(
  (Ref ref) => FavoriteRepository(prefs: ref.watch(prefsStoreProvider)),
);

/// MoviePilot 实例仓库。
final Provider<MpRepository> mpRepositoryProvider = Provider<MpRepository>(
  (Ref ref) => MpRepository(
    prefs: ref.watch(prefsStoreProvider),
    secure: ref.watch(secureStoreProvider),
  ),
);

/// MoviePilot 地址探测（连接测试）。
final Provider<MpReachabilityProbe> mpProbeProvider = Provider<MpReachabilityProbe>(
  (Ref ref) => MpReachabilityProbe(dio: ref.watch(proxyRuntimeProvider).createDio()),
);

/// 单个 MoviePilot 实例的双通道选路器：内网优先（2 秒）、失败回退外网（10 秒），
/// 成功结果缓存 5 分钟，网络变化或探测失败时失效重选——与 NAS 服务地址同一套策略。
final ProviderFamily<EndpointResolver, String> mpEndpointResolverProvider =
    Provider.family<EndpointResolver, String>((Ref ref, String instanceId) {
  final MpInstance? instance = ref.watch(mpByIdProvider(instanceId));
  final MpReachabilityProbe probe = ref.watch(mpProbeProvider);
  final EndpointResolver resolver = EndpointResolver(
    // MP 没有 /api/v1/health，可用性以「能否拿到站点响应」为准（401/403 也算连通）。
    probe: (Uri candidate, Duration timeout) async {
      final SiteProbeResult result = await probe(candidate.toString(), timeout: timeout);
      return result.isSuccess;
    },
    profile: EndpointProfile(
      lanBaseUrl: instance?.lanUri,
      wanBaseUrl: instance?.wanUri,
    ),
  );
  // 网络环境变化时立即失效，保证回到家庭网络后下一次请求自动切回内网。
  ref.listen(connectivityProvider, (_, _) => resolver.invalidate());
  return resolver;
});

/// 某个 MP 实例当前实际生效的地址与链路（无可用通道时为 null）。
final FutureProviderFamily<ResolvedEndpoint?, String> mpActiveEndpointProvider =
    FutureProvider.family<ResolvedEndpoint?, String>((Ref ref, String instanceId) async {
  final MpInstance? instance = ref.watch(mpByIdProvider(instanceId));
  if (instance == null || !instance.hasAnyAddress) return null;
  try {
    return await ref.watch(mpEndpointResolverProvider(instanceId)).resolve();
  } on EndpointUnavailableException {
    return null;
  }
});

/// MoviePilot 实例清单。
final AsyncNotifierProvider<MpListNotifier, List<MpInstance>> mpListProvider =
    AsyncNotifierProvider<MpListNotifier, List<MpInstance>>(MpListNotifier.new);

class MpListNotifier extends AsyncNotifier<List<MpInstance>> {
  MpRepository get _repo => ref.read(mpRepositoryProvider);

  @override
  Future<List<MpInstance>> build() async => _repo.loadAll();

  void _reload() => state = AsyncData<List<MpInstance>>(_repo.loadAll());

  Future<MpInstance> upsert(MpInstance instance) async {
    final MpInstance stored = await _repo.upsert(instance);
    _reload();
    return stored;
  }

  Future<void> remove(String instanceId) async {
    await _repo.remove(instanceId);
    _reload();
  }

  Future<void> saveCredential(String instanceId, Map<String, dynamic> credential) async {
    await _repo.saveCredential(instanceId, credential);
    await _update(instanceId, (MpInstance i) => i.copyWith(credentialConfigured: true));
  }

  Future<void> clearCredential(String instanceId) async {
    await _repo.deleteCredential(instanceId);
    await _update(instanceId, (MpInstance i) => i.copyWith(credentialConfigured: false));
  }

  Future<void> recordProbe(String instanceId, bool reachable) => _update(
        instanceId,
        (MpInstance i) => i.copyWith(
          health: reachable ? ServiceHealth.ok : ServiceHealth.danger,
          lastTestedAt: DateTime.now(),
        ),
      );

  Future<void> toggleEnabled(String instanceId) =>
      _update(instanceId, (MpInstance i) => i.copyWith(enabled: !i.enabled));

  /// 切换「用于搜索增强」；适配器不支持搜索的版本会被拒绝。
  Future<bool> toggleSearchEnhance(String instanceId) async {
    final MpInstance? instance = ref.read(mpByIdProvider(instanceId));
    if (instance == null) return false;
    if (!MoviePilotAdapterRegistry.of(instance.version).supportsSearch) return false;
    await _update(instanceId, (MpInstance i) => i.copyWith(searchEnhance: !i.searchEnhance));
    return true;
  }

  Future<void> _update(String instanceId, MpInstance Function(MpInstance) transform) async {
    final List<MpInstance> list = _repo.loadAll();
    await _repo.saveAll(
      list
          .map((MpInstance i) =>
              i.id == instanceId ? transform(i).copyWith(updatedAt: DateTime.now()) : i)
          .toList(growable: false),
    );
    _reload();
  }
}

/// 按 id 取单个 MoviePilot 实例。
final ProviderFamily<MpInstance?, String> mpByIdProvider =
    Provider.family<MpInstance?, String>((Ref ref, String instanceId) {
  final List<MpInstance> list = ref.watch(mpListProvider).valueOrNull ?? const <MpInstance>[];
  for (final MpInstance instance in list) {
    if (instance.id == instanceId) return instance;
  }
  return null;
});

/// 实际参与搜索增强的实例 id（启用 + 适配器支持搜索 + 用户已开启增强）。
final Provider<List<String>> searchEnhanceInstanceIdsProvider = Provider<List<String>>((Ref ref) {
  final List<MpInstance> list = ref.watch(mpListProvider).valueOrNull ?? const <MpInstance>[];
  return MoviePilotAdapterRegistry.enhanceInstanceIds(list);
});

/// 收藏清单。
final AsyncNotifierProvider<FavoriteNotifier, List<FavoriteItem>> favoritesProvider =
    AsyncNotifierProvider<FavoriteNotifier, List<FavoriteItem>>(FavoriteNotifier.new);

class FavoriteNotifier extends AsyncNotifier<List<FavoriteItem>> {
  FavoriteRepository get _repo => ref.read(favoriteRepositoryProvider);

  @override
  Future<List<FavoriteItem>> build() async => _repo.loadAll();

  /// 切换收藏，返回切换后的状态。
  Future<bool> toggle(FavoriteItem item) async {
    final bool favorited = await _repo.toggle(item);
    state = AsyncData<List<FavoriteItem>>(_repo.loadAll());
    return favorited;
  }

  Future<void> remove(String key) async {
    await _repo.remove(key);
    state = AsyncData<List<FavoriteItem>>(_repo.loadAll());
  }

  bool contains(String key) => _repo.contains(key);
}

/// 单站检索阶段（实时展示的进度口径，参考实现同样逐站给出状态）。
enum SiteSearchPhase {
  queued('排队中'),
  working('检索中'),
  success('完成'),
  failed('失败'),
  cancelled('已取消');

  const SiteSearchPhase(this.label);

  final String label;

  /// 是否已经不再变化（完成 / 失败 / 已取消）。
  bool get isDone =>
      this == SiteSearchPhase.success ||
      this == SiteSearchPhase.failed ||
      this == SiteSearchPhase.cancelled;
}

/// 单个站点的检索进度。
class SiteSearchStatus {
  const SiteSearchStatus({
    required this.siteId,
    required this.siteName,
    this.phase = SiteSearchPhase.queued,
    this.itemCount = 0,
    this.message = '',
    this.hasMore = false,
  });

  final String siteId;
  final String siteName;
  final SiteSearchPhase phase;

  /// 本页返回条数。
  final int itemCount;

  /// 失败原因（仅失败时给）。
  final String message;

  /// 该站是否还有下一页（用于「加载更多」只找真正有下一页的站点）。
  final bool hasMore;

  SiteSearchStatus copyWith({
    SiteSearchPhase? phase,
    int? itemCount,
    String? message,
    bool? hasMore,
  }) =>
      SiteSearchStatus(
        siteId: siteId,
        siteName: siteName,
        phase: phase ?? this.phase,
        itemCount: itemCount ?? this.itemCount,
        message: message ?? this.message,
        hasMore: hasMore ?? this.hasMore,
      );
}

/// 逐站检索函数（可注入：便于测试控制每站何时返回，也便于控制并发）。
typedef SiteSearchFn = Future<SearchPageResult> Function(
  SearchRequest request, {
  CancelToken? cancelToken,
});

/// 默认实现：把单站请求交给 [searchApiProvider]。
final Provider<SiteSearchFn> siteSearchFnProvider = Provider<SiteSearchFn>(
  (Ref ref) => (SearchRequest request, {CancelToken? cancelToken}) =>
      ref.read(searchApiProvider).search(request, cancelToken: cancelToken),
);

/// 跨站合并后的统一排序。
///
/// 各站分别按自己的顺序返回，合并后若不重排，列表顺序会随「哪个站先返回」而跳动；
/// 这里对合并结果整体重排，并保证同键项顺序稳定（否则每次增量刷新都在闪）。
List<SearchResultItem> sortSearchResults(List<SearchResultItem> items, SortOption sort) {
  final List<SearchResultItem> sorted = List<SearchResultItem>.of(items);
  int compare(SearchResultItem a, SearchResultItem b) {
    final int result = switch (sort) {
      // 相关度由后端决定，这里保持插入次序（稳定），不做二次排序。
      SortOption.relevance => 0,
      SortOption.seeders => b.seeders.compareTo(a.seeders),
      SortOption.published => _compareDate(b.publishedAt, a.publishedAt),
      SortOption.size => b.sizeBytes.compareTo(a.sizeBytes),
    };
    if (result != 0) return result;
    final int bySite = a.siteName.compareTo(b.siteName);
    return bySite != 0 ? bySite : a.title.compareTo(b.title);
  }

  sorted.sort(compare);
  return sorted;
}

int _compareDate(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  return a.compareTo(b);
}

/// 搜索页状态。
class SearchState {
  const SearchState({
    this.keyword = '',
    this.scope = SearchScope.allSites,
    this.promotion = PromotionFilter.all,
    this.sort = SortOption.relevance,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.result,
    this.history = const <String>[],
    this.progress = const <String, SiteSearchStatus>{},
    this.running = false,
    this.stopped = false,
    this.notice,
  });

  final String keyword;
  final SearchScope scope;
  final PromotionFilter promotion;
  final SortOption sort;
  final bool loading;
  final bool loadingMore;
  final String? error;
  final SearchPageResult? result;
  final List<String> history;

  /// 逐站检索进度（实时展示用）；为空表示本次不是逐站模式。
  final Map<String, SiteSearchStatus> progress;

  /// 逐站检索是否仍在进行。
  final bool running;

  /// 是否被用户中途停止。
  final bool stopped;

  /// 服务端提示（如部分站点失败、搜索增强降级）。
  final String? notice;

  bool get hasKeyword => keyword.trim().isNotEmpty;

  /// 是否处于逐站（实时）模式。
  bool get streaming => progress.isNotEmpty;

  int get totalSites => progress.length;

  int get doneSites => progress.values.where((SiteSearchStatus s) => s.phase.isDone).length;

  int get successSites =>
      progress.values.where((SiteSearchStatus s) => s.phase == SiteSearchPhase.success).length;

  List<SiteSearchStatus> get failedSites => progress.values
      .where((SiteSearchStatus s) => s.phase == SiteSearchPhase.failed)
      .toList(growable: false);

  /// 已收到的结果条数（增量可见的数字）。
  int get receivedCount => result?.items.length ?? 0;

  /// 当前还可能有下一页的站点 id。
  List<String> get sitesWithMore => progress.values
      .where((SiteSearchStatus s) => s.phase == SiteSearchPhase.success && s.hasMore)
      .map((SiteSearchStatus s) => s.siteId)
      .toList(growable: false);

  SearchState copyWith({
    String? keyword,
    SearchScope? scope,
    PromotionFilter? promotion,
    SortOption? sort,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
    SearchPageResult? result,
    List<String>? history,
    Map<String, SiteSearchStatus>? progress,
    bool? running,
    bool? stopped,
    String? notice,
    bool clearNotice = false,
  }) =>
      SearchState(
        keyword: keyword ?? this.keyword,
        scope: scope ?? this.scope,
        promotion: promotion ?? this.promotion,
        sort: sort ?? this.sort,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        error: clearError ? null : (error ?? this.error),
        result: result ?? this.result,
        history: history ?? this.history,
        progress: progress ?? this.progress,
        running: running ?? this.running,
        stopped: stopped ?? this.stopped,
        notice: clearNotice ? null : (notice ?? this.notice),
      );
}

/// 搜索控制器：筛选条件、执行搜索、分页与历史记录。
final NotifierProvider<SearchController, SearchState> searchControllerProvider =
    NotifierProvider<SearchController, SearchState>(SearchController.new);

class SearchController extends Notifier<SearchState> {
  static const int maxHistory = 10;

  PrefsStore get _prefs => ref.read(prefsStoreProvider);

  @override
  SearchState build() => SearchState(
        history: _prefs.getStringList(PrefKeys.searchHistory) ?? const <String>[],
      );

  /// 分页大小（可在偏好中调整）。
  int get pageSize => _prefs.getInt(PrefKeys.searchPageSize) ?? 50;

  Future<void> setScope(SearchScope scope) async {
    state = state.copyWith(scope: scope);
    // 收藏范围由本地收藏列表渲染，不需要请求后端。
    if (scope == SearchScope.favorites) return;
    if (state.hasKeyword) await _run(page: 1, append: false);
  }

  Future<void> setPromotion(PromotionFilter promotion) async {
    state = state.copyWith(promotion: promotion);
    if (state.hasKeyword && state.scope != SearchScope.favorites) {
      await _run(page: 1, append: false);
    }
  }

  Future<void> setSort(SortOption sort) async {
    state = state.copyWith(sort: sort);
    // 逐站结果的顺序本来就是客户端统一重排，换排序不必重新请求后端；
    // 进行中的逐站检索也会按新排序继续发布（publish 读的是最新 sort）。
    if (state.streaming && state.result != null) {
      state = state.copyWith(
        result: state.result!.copyWith(
          items: sortSearchResults(state.result!.items, sort),
        ),
      );
      return;
    }
    if (state.hasKeyword && state.scope != SearchScope.favorites) {
      await _run(page: 1, append: false);
    }
  }

  Future<void> submit(String keyword) async {
    final String value = keyword.trim();
    if (value.isEmpty) {
      state = state.copyWith(keyword: '', result: null, clearError: true, loading: false);
      return;
    }
    state = state.copyWith(keyword: value);
    await _remember(value);
    if (state.scope == SearchScope.favorites) return;
    await _run(page: 1, append: false);
  }

  Future<void> retry() => _run(page: 1, append: false);

  Future<void> loadMore() {
    if (state.loadingMore || state.running || !(state.result?.hasMore ?? false)) {
      return Future<void>.value();
    }
    return _run(page: (state.result?.page ?? 1) + 1, append: true);
  }

  Future<void> clearKeyword() async {
    state = state.copyWith(keyword: '', result: null, clearError: true);
  }

  Future<void> _remember(String keyword) async {
    final List<String> history = <String>[
      keyword,
      ...state.history.where((String item) => item != keyword),
    ];
    final List<String> trimmed =
        history.length > maxHistory ? history.sublist(0, maxHistory) : history;
    await _prefs.setStringList(PrefKeys.searchHistory, trimmed);
    state = state.copyWith(history: trimmed);
  }

  /// 逐站并发上限：与浏览器端参考实现一致，避免把后端与站点同时打满。
  static const int siteConcurrency = 3;

  /// 本次逐站检索的令牌：停止或新搜索都会递增，旧任务的写入据此丢弃。
  int _runToken = 0;
  CancelToken? _cancelToken;

  /// 中途停止：取消在飞请求，保留已经收到的结果。
  Future<void> stop() async {
    if (!state.running && !state.loading) return;
    _runToken++;
    _cancelToken?.cancel('用户停止搜索');
    _cancelToken = null;
    final Map<String, SiteSearchStatus> progress = <String, SiteSearchStatus>{
      for (final MapEntry<String, SiteSearchStatus> entry in state.progress.entries)
        entry.key: entry.value.phase.isDone
            ? entry.value
            : entry.value.copyWith(phase: SiteSearchPhase.cancelled),
    };
    state = state.copyWith(
      running: false,
      loading: false,
      loadingMore: false,
      stopped: true,
      progress: progress,
      notice: '已停止搜索：保留已经收到的 ${state.receivedCount} 条结果',
    );
  }

  Future<void> _run({required int page, required bool append}) async {
    if (!state.hasKeyword) return;
    if (state.scope == SearchScope.favorites) return;

    // 站点清单是异步加载的：用户可能没打开过站点页就直接搜索。
    // 先等一次，否则会把「已启用站点」当成空集而退回全量检索（逐站进度也就没了）。
    List<PtSite> sites = ref.read(siteListProvider).valueOrNull ?? const <PtSite>[];
    if (sites.isEmpty) {
      try {
        sites = await ref.read(siteListProvider.future);
      } catch (_) {
        sites = const <PtSite>[];
      }
      if (!state.hasKeyword) return;
    }
    final List<PtSite> localSites = sites.where((PtSite s) => s.enabled).toList(growable: false);

    // 本地有站点清单就逐站请求：每站返回立刻并入结果，边搜边出。
    // 本地没有清单时只能让后端做一次全量检索（那种情况不存在「逐站进度」）。
    if (localSites.isEmpty) {
      await _runAggregate(page: page, append: append);
      return;
    }
    await _runProgressive(page: page, append: append, sites: localSites);
  }

  /// 逐站检索：并发受限的队列 + 逐站回填，支持中途停止。
  Future<void> _runProgressive({
    required int page,
    required bool append,
    required List<PtSite> sites,
  }) async {
    final int token = ++_runToken;
    final CancelToken cancelToken = CancelToken();
    _cancelToken = cancelToken;

    final List<PtSite> queue = <PtSite>[];
    final Map<String, SiteSearchStatus> progress = <String, SiteSearchStatus>{};

    if (append) {
      // 「加载更多」只找真正还有下一页的站点，其余保持上一次的结论。
      final Set<String> more = state.sitesWithMore.toSet();
      for (final PtSite site in sites) {
        if (more.contains(site.id)) {
          queue.add(site);
          progress[site.id] =
              state.progress[site.id]!.copyWith(phase: SiteSearchPhase.queued, message: '');
        }
      }
      for (final MapEntry<String, SiteSearchStatus> entry in state.progress.entries) {
        progress.putIfAbsent(entry.key, () => entry.value);
      }
    } else {
      for (final PtSite site in sites) {
        queue.add(site);
        progress[site.id] = SiteSearchStatus(siteId: site.id, siteName: site.name);
      }
    }

    if (queue.isEmpty) {
      state = state.copyWith(loadingMore: false, notice: '没有更多结果了');
      return;
    }

    final List<SearchResultItem> collected = append
        ? List<SearchResultItem>.of(state.result?.items ?? const <SearchResultItem>[])
        : <SearchResultItem>[];
    final Set<String> seen = <String>{
      for (final SearchResultItem item in collected) item.favoriteKey,
    };
    final List<String> mpInstanceIds = ref.read(searchEnhanceInstanceIdsProvider);

    state = state.copyWith(
      loading: false,
      loadingMore: append,
      running: true,
      stopped: false,
      clearError: true,
      clearNotice: true,
      progress: progress,
    );

    /// 每站完成就重排并发布一次——这就是「实时展示」的落点。
    ///
    /// 结果按 [sortSearchResults] 统一重排：各站各自排好序，合并后不重排的话
    /// 顺序会随「哪个站先返回」跳动。逐站请求都带 MP 增强 id，MP 命中由
    /// [SearchResultItem.favoriteKey] 去重，重复返回不会出现重复卡片。
    void publish() {
      if (token != _runToken) return;
      final bool hasMore = progress.values.any((SiteSearchStatus s) => s.hasMore);
      state = state.copyWith(
        result: SearchPageResult(
          items: sortSearchResults(collected, state.sort),
          page: page,
          pageSize: pageSize,
          hasMore: hasMore,
        ),
        progress: <String, SiteSearchStatus>{...progress},
      );
    }

    Future<void> worker() async {
      while (true) {
        if (token != _runToken || cancelToken.isCancelled) return;
        if (queue.isEmpty) return;
        final PtSite site = queue.removeAt(0);
        progress[site.id] = progress[site.id]!.copyWith(phase: SiteSearchPhase.working);
        publish();

        try {
          final SearchPageResult result = await ref.read(siteSearchFnProvider)(
            SearchRequest(
              keyword: state.keyword,
              siteIds: <String>[site.id],
              mpInstanceIds: mpInstanceIds,
              promotion: state.promotion,
              sort: state.sort,
              page: page,
              pageSize: pageSize,
            ),
            cancelToken: cancelToken,
          );
          if (token != _runToken) return;
          for (final SearchResultItem item in result.items) {
            if (seen.add(item.favoriteKey)) collected.add(item);
          }
          progress[site.id] = progress[site.id]!.copyWith(
            phase: SiteSearchPhase.success,
            itemCount: result.items.length,
            hasMore: result.hasMore,
            message: result.siteErrors[site.name] ?? '',
          );
        } on ApiException catch (error) {
          if (token != _runToken) return;
          progress[site.id] = progress[site.id]!.copyWith(
            phase: cancelToken.isCancelled ? SiteSearchPhase.cancelled : SiteSearchPhase.failed,
            message: error.message,
          );
        } on EndpointUnavailableException catch (error) {
          if (token != _runToken) return;
          progress[site.id] = progress[site.id]!.copyWith(
            phase: cancelToken.isCancelled ? SiteSearchPhase.cancelled : SiteSearchPhase.failed,
            message: error.toString(),
          );
        } catch (error) {
          if (token != _runToken) return;
          progress[site.id] = progress[site.id]!.copyWith(
            phase: cancelToken.isCancelled ? SiteSearchPhase.cancelled : SiteSearchPhase.failed,
            message: '$error',
          );
        }
        publish();
      }
    }

    final int workers = queue.length < siteConcurrency ? queue.length : siteConcurrency;
    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < workers; i++) worker(),
    ]);

    // 被用户停止或被新搜索接管：状态已由 stop() / 新任务写入，这里不再覆盖。
    if (token != _runToken) return;

    final int failedCount =
        progress.values.where((SiteSearchStatus s) => s.phase == SiteSearchPhase.failed).length;
    state = state.copyWith(
      running: false,
      loadingMore: false,
      stopped: false,
      progress: progress,
      notice: failedCount == 0 ? null : '有 $failedCount 个站点检索失败，点「搜索状态」查看原因',
      clearNotice: failedCount == 0,
    );
  }

  /// 聚合检索：后端一次返回全部（本地无站点清单时走这里）。
  Future<void> _runAggregate({required int page, required bool append}) async {
    state = state.copyWith(
      loading: !append,
      loadingMore: append,
      clearError: true,
      clearNotice: true,
      progress: const <String, SiteSearchStatus>{},
      running: false,
      stopped: false,
    );

    final List<PtSite> sites = ref.read(siteListProvider).valueOrNull ?? const <PtSite>[];
    final List<String> siteIds = state.scope == SearchScope.enabledSites
        ? sites.where((PtSite s) => s.enabled).map((PtSite s) => s.id).toList(growable: false)
        : const <String>[];

    try {
      final SearchPageResult result = await ref.read(searchApiProvider).search(
            SearchRequest(
              keyword: state.keyword,
              siteIds: siteIds,
              mpInstanceIds: ref.read(searchEnhanceInstanceIdsProvider),
              promotion: state.promotion,
              sort: state.sort,
              page: page,
              pageSize: pageSize,
            ),
          );

      final List<SearchResultItem> items = append
          ? <SearchResultItem>[...?state.result?.items, ...result.items]
          : result.items;
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        result: result.copyWith(items: items, page: page),
        notice: result.hasSiteErrors
            ? '有 ${result.siteErrors.length} 个站点检索失败'
            : (result.notice.isEmpty ? null : result.notice),
      );
    } on ApiException catch (error) {
      state = state.copyWith(loading: false, loadingMore: false, error: error.message);
    } on EndpointUnavailableException catch (error) {
      state = state.copyWith(loading: false, loadingMore: false, error: error.toString());
    }
  }
}