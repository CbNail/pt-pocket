import '../models/pt_site.dart';
import 'app_keys.dart';
import 'prefs_store.dart';
import 'secure_store.dart';

/// 站点仓库：站点清单走非敏感偏好存储，站点凭据走本机安全存储。
///
/// 约束：
/// - 清单只存非机密字段（名称、地址、框架、认证方式、状态标记）；
/// - 凭据（Cookie / Passkey / API Key / 账号密码）只进 [SecureStore]；
/// - 删除站点时一并清理该站凭据，避免留下孤儿密钥。
class SiteRepository {
  SiteRepository({required this.prefs, required this.secure});

  final PrefsStore prefs;
  final SecureStore secure;

  static const int storageVersion = 1;

  /// 读取全部站点（同步，无副作用）。
  List<PtSite> loadAll() {
    final Map<String, dynamic>? raw = prefs.getJson(PrefKeys.siteIndex);
    if (raw == null) return <PtSite>[];
    final Object? sites = raw['sites'];
    if (sites is! List) return <PtSite>[];
    return sites
        .whereType<Map<String, dynamic>>()
        .map(PtSite.fromJson)
        .where((PtSite s) => s.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> saveAll(List<PtSite> sites) => prefs.setJson(PrefKeys.siteIndex, <String, dynamic>{
        'version': storageVersion,
        'sites': sites.map((PtSite s) => s.toJson()).toList(growable: false),
      });

  /// 新增或更新（按 id 覆盖），返回落库后的对象。
  Future<PtSite> upsert(PtSite site) async {
    final List<PtSite> sites = loadAll().toList();
    final DateTime now = DateTime.now();
    final PtSite stored = site.copyWith(
      createdAt: site.createdAt ?? now,
      updatedAt: now,
    );
    final int index = sites.indexWhere((PtSite s) => s.id == site.id);
    if (index >= 0) {
      sites[index] = stored;
    } else {
      sites.add(stored);
    }
    await saveAll(sites);
    return stored;
  }

  /// 删除站点及其凭据。
  Future<void> remove(String siteId) async {
    final List<PtSite> sites = loadAll().where((PtSite s) => s.id != siteId).toList(growable: false);
    await saveAll(sites);
    await deleteCredential(siteId);
  }

  Future<void> saveCredential(String siteId, Map<String, dynamic> credential) =>
      secure.writeJson(SecureKeys.siteCredential(siteId), credential);

  Future<Map<String, dynamic>?> readCredential(String siteId) =>
      secure.readJson(SecureKeys.siteCredential(siteId));

  Future<void> deleteCredential(String siteId) =>
      secure.delete(SecureKeys.siteCredential(siteId));

  Future<bool> hasCredential(String siteId) async => await readCredential(siteId) != null;
}