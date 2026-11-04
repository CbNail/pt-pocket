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

  bool get hasKeyword => keyword.trim().isNotEmpty;

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
    if (state.loadingMore || !(state.result?.hasMore ?? false)) return Future<void>.value();
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

  Future<void> _run({required int page, required bool append}) async {
    if (!state.hasKeyword) return;
    state = state.copyWith(loading: !append, loadingMore: append, clearError: true);

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
      );
    } on ApiException catch (error) {
      state = state.copyWith(loading: false, loadingMore: false, error: error.message);
    } on EndpointUnavailableException catch (error) {
      state = state.copyWith(loading: false, loadingMore: false, error: error.toString());
    }
  }
}