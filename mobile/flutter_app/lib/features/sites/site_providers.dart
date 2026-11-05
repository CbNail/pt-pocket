import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/adapters/site_adapter_registry.dart';
import '../../core/direct/direct_providers.dart';
import '../../core/direct/nexusphp_client.dart';
import '../../core/models/moviepilot.dart';
import '../../core/models/pt_site.dart';
import '../../core/providers.dart';
import '../../core/services/cookiecloud_service.dart';
import '../../core/services/ptd_backup_importer.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/storage/site_repository.dart';

/// 站点仓库（清单走偏好存储、凭据走安全存储）。
final Provider<SiteRepository> siteRepositoryProvider = Provider<SiteRepository>(
  (Ref ref) => SiteRepository(
    prefs: ref.watch(prefsStoreProvider),
    secure: ref.watch(secureStoreProvider),
  ),
);

/// 站点直连探测（连接测试）；Dio 统一经 [ProxyRuntime] 套用 App 代理设置。
final Provider<SiteReachabilityProbe> siteProbeProvider = Provider<SiteReachabilityProbe>(
  (Ref ref) => SiteReachabilityProbe(
    dio: ref.watch(proxyRuntimeProvider).createDio(),
  ),
);

/// CookieCloud 服务（同样套用 App 代理设置）。
final Provider<CookieCloudService> cookieCloudServiceProvider = Provider<CookieCloudService>(
  (Ref ref) => CookieCloudService(
    dio: ref.watch(proxyRuntimeProvider).createDio(),
  ),
);

/// PTD / PT-depiler 备份导入器。
final Provider<PtdBackupImporter> ptdImporterProvider =
    Provider<PtdBackupImporter>((Ref ref) => const PtdBackupImporter());

/// 站点清单状态。
final AsyncNotifierProvider<SiteListNotifier, List<PtSite>> siteListProvider =
    AsyncNotifierProvider<SiteListNotifier, List<PtSite>>(SiteListNotifier.new);

class SiteListNotifier extends AsyncNotifier<List<PtSite>> {
  SiteRepository get _repo => ref.read(siteRepositoryProvider);

  @override
  Future<List<PtSite>> build() async {
    final List<PtSite> sites = _repo.loadAll();
    // 凭据可能由更早的版本、CookieCloud 或 PTD 备份直接写进安全存储而没有同步标记；
    // 这里在后台按安全存储的真实内容校正一次「是否已配置凭据」，不阻塞首屏。
    unawaited(reconcileCredentials(sites));
    return sites;
  }

  /// 按本机安全存储校正每个站点的「已配置凭据」标记。
  ///
  /// 返回被修正的站点数。有此校正，「凭据其实在、标记却是未配置」的旧数据会自愈，
  /// 界面不会再出现「可访问、已连通却仍显示缺少凭据」。
  Future<int> reconcileCredentials([List<PtSite>? input]) async {
    final List<PtSite> sites = input ?? _repo.loadAll();
    int fixed = 0;
    final List<PtSite> next = <PtSite>[];
    for (final PtSite site in sites) {
      final bool has = await _repo.hasCredential(site.id);
      if (has != site.credentialConfigured) {
        fixed++;
        next.add(
          site.copyWith(
            credentialConfigured: has,
            updatedAt: DateTime.now(),
          ),
        );
      } else {
        next.add(site);
      }
    }
    if (fixed > 0) {
      await _repo.saveAll(next);
      _reload();
    }
    return fixed;
  }

  void _reload() => state = AsyncData<List<PtSite>>(_repo.loadAll());

  Future<PtSite> upsert(PtSite site) async {
    final PtSite stored = await _repo.upsert(site);
    _reload();
    return stored;
  }

  Future<void> remove(String siteId) async {
    await _repo.remove(siteId);
    _reload();
  }

  /// 写入凭据并标记「已配置」，同时把连接状态重置为未测试。
  Future<void> saveCredential(String siteId, Map<String, dynamic> credential) async {
    await _repo.saveCredential(siteId, credential);
    final List<PtSite> sites = _repo.loadAll();
    await _repo.saveAll(
      sites
          .map((PtSite s) => s.id == siteId
              ? s.copyWith(credentialConfigured: true, health: SiteHealth.unknown, updatedAt: DateTime.now())
              : s)
          .toList(growable: false),
    );
    _reload();
  }

  Future<void> clearCredential(String siteId) async {
    await _repo.deleteCredential(siteId);
    final List<PtSite> sites = _repo.loadAll();
    await _repo.saveAll(
      sites
          .map((PtSite s) => s.id == siteId
              ? s.copyWith(credentialConfigured: false, updatedAt: DateTime.now())
              : s)
          .toList(growable: false),
    );
    _reload();
  }

  /// 记录连接测试结果。
  Future<void> recordProbe(String siteId, SiteProbeResult result) async {
    final List<PtSite> sites = _repo.loadAll();
    await _repo.saveAll(
      sites
          .map((PtSite s) => s.id == siteId
              ? s.copyWith(
                  health: result.isSuccess ? SiteHealth.ok : SiteHealth.danger,
                  lastTestedAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                )
              : s)
          .toList(growable: false),
    );
    _reload();
  }

  Future<void> toggleFavorite(String siteId) async {
    final List<PtSite> sites = _repo.loadAll();
    await _repo.saveAll(
      sites
          .map((PtSite s) => s.id == siteId ? s.copyWith(favorite: !s.favorite) : s)
          .toList(growable: false),
    );
    _reload();
  }

  Future<void> toggleEnabled(String siteId) async {
    final List<PtSite> sites = _repo.loadAll();
    await _repo.saveAll(
      sites
          .map((PtSite s) => s.id == siteId ? s.copyWith(enabled: !s.enabled) : s)
          .toList(growable: false),
    );
    _reload();
  }
}

/// 按 id 取单个站点（不存在时为 null）。
final ProviderFamily<PtSite?, String> siteByIdProvider =
    Provider.family<PtSite?, String>((Ref ref, String siteId) {
  final List<PtSite> sites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];
  for (final PtSite site in sites) {
    if (site.id == siteId) return site;
  }
  return null;
});

/// 站点凭据（异步读取安全存储）。
final FutureProviderFamily<Map<String, dynamic>?, String> siteCredentialProvider =
    FutureProvider.family<Map<String, dynamic>?, String>(
  (Ref ref, String siteId) => ref.watch(siteRepositoryProvider).readCredential(siteId),
);

/// 站点资源列表查询参数（同一站点 + 关键词 + 页码）。
typedef SiteResourceQuery = ({String siteId, String keyword, int page});

/// 站点资源列表：App 逐站直连站点 `torrents.php`（无关键词时即该站最新资源）。
///
/// 与搜索同一条链路（带该站 Cookie、解析同一批字段），因此失败原因也按站归因：
/// 缺少凭据 / 登录态失效 / 被限流 / 网络不可达 / 页面结构未识别。
final FutureProviderFamily<SearchPageResult, SiteResourceQuery> siteResourcesProvider =
    FutureProvider.family<SearchPageResult, SiteResourceQuery>(
  (Ref ref, SiteResourceQuery query) async {
    final PtSite? site = ref.watch(siteByIdProvider(query.siteId));
    if (site == null) {
      throw const SiteFetchException(
        kind: SiteFetchFailureKind.unparsed,
        message: '站点已不存在，请返回站点页刷新后重试',
      );
    }
    final Map<String, dynamic>? credential =
        await ref.watch(siteCredentialProvider(query.siteId).future);
    return ref.watch(nexusPhpClientProvider).search(
          site,
          keyword: query.keyword,
          page: query.page,
          pageSize: 50,
          credential: credential,
        );
  },
);

/// 当前站点的适配定义。
final ProviderFamily<SiteAdapterDescriptor, SiteFramework> siteAdapterProvider =
    Provider.family<SiteAdapterDescriptor, SiteFramework>(
  (Ref ref, SiteFramework framework) => SiteAdapterRegistry.of(framework),
);