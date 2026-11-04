import 'package:dio/dio.dart';

import '../models/moviepilot.dart';
import '../models/pt_site.dart';
import '../services/search_api.dart';
import 'nexusphp_client.dart';

/// 站内检索数据通道：**逐站直连优先**，NAS 后端可用时对失败的站点回退。
///
/// 逐站模式下（`siteIds` 只含一个站点）直接请求该站点的 `torrents.php?search=`，
/// 因此站点「地址正常」时检索就能真的跑起来；只有站点的 Cookie 缺失 / 网络不通
/// 这类本地无法解决的情况，才回退到 NAS 后端，并保留最贴近用户的那条失败原因。
class SiteSearchGateway {
  SiteSearchGateway(
    this._nasConfigured,
    this._resolveSite,
    this._resolveCredential, {
    required this.direct,
    required this.nas,
  });

  final NexusPhpClient direct;
  final SearchApi nas;
  final bool Function() _nasConfigured;
  final PtSite? Function(String siteId) _resolveSite;
  final Future<Map<String, dynamic>?> Function(String siteId) _resolveCredential;

  bool get nasAvailable => _nasConfigured();

  Future<SearchPageResult> search(SearchRequest request, {CancelToken? cancelToken}) async {
    // 聚合模式（没有指定站点）：只能交给 NAS 后端。
    if (request.siteIds.isEmpty) {
      if (!nasAvailable) {
        throw const SiteFetchException(
          kind: SiteFetchFailureKind.missingCredential,
          message: '未指定站点：聚合检索需要 NAS 后端；请选择「已启用站点」按站直连检索',
        );
      }
      return nas.search(request, cancelToken: cancelToken);
    }

    final String siteId = request.siteIds.first;
    final PtSite? site = _resolveSite(siteId);
    if (site == null) {
      if (nasAvailable) return nas.search(request, cancelToken: cancelToken);
      throw SiteFetchException(
        kind: SiteFetchFailureKind.unparsed,
        message: '站点已不存在（$siteId），请返回站点页刷新后重试',
      );
    }

    final Map<String, dynamic>? credential = await _resolveCredential(siteId);
    try {
      return await direct.search(
        site,
        keyword: request.keyword,
        page: request.page,
        pageSize: request.pageSize,
        credential: credential,
        promotion: request.promotion,
        cancelToken: cancelToken,
      );
    } on SiteFetchException catch (error) {
      final bool localProblem = error.kind == SiteFetchFailureKind.missingCredential ||
          error.kind == SiteFetchFailureKind.network ||
          error.kind == SiteFetchFailureKind.rateLimited;
      if (nasAvailable && localProblem) {
        // 后端可用时让它再试一次；后端也失败则保留直连的失败原因（更贴近本地实际）。
        try {
          return await nas.search(request, cancelToken: cancelToken);
        } catch (_) {
          rethrow;
        }
      }
      rethrow;
    }
  }
}