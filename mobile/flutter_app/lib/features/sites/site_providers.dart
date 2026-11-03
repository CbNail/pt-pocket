import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/adapters/site_adapter_registry.dart';
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
  Future<List<PtSite>> build() async => _repo.loadAll();

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

/// 当前站点的适配定义。
final ProviderFamily<SiteAdapterDescriptor, SiteFramework> siteAdapterProvider =
    Provider.family<SiteAdapterDescriptor, SiteFramework>(
  (Ref ref, SiteFramework framework) => SiteAdapterRegistry.of(framework),
);