import 'package:dio/dio.dart';

import '../models/moviepilot.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';

/// NAS 后端「聚合搜索与推送」接口契约（客户端侧）。
///
/// 契约：
/// - `POST /api/v1/search`：body 为 [SearchRequest.toJson]，返回一页归一化结果
///   （`items` / `page` / `pageSize` / `hasMore` / `siteErrors`）；
/// - `POST /api/v1/torrents/push`：body `{downloadUrl, downloaderId, savePath?, category?, mpInstanceId?}`。
///
/// 站点并发检索、跨站去重、凭据携带与下载地址抓取全部由 NAS 后端完成（规格书 §7.1），
/// 移动端不直连站点页面。
///
/// 实时展示的实现方式：把一次「全量搜索」拆成**逐站请求**（`siteIds` 只放一个站点），
/// 每站返回就立刻并入结果列表——这样搜索结果边搜边出，不必等最慢的站点。
/// 这与参考实现（PT-depiler）在浏览器里按站点并发查询、逐站回填的做法一致，
/// 且完全落在现有契约上，不需要后端额外支持流式接口。
class SearchApi {
  SearchApi({required this.client});

  final ApiClient client;

  static const String searchPath = '/api/v1/search';
  static const String pushPath = '/api/v1/torrents/push';

  /// 聚合搜索。[cancelToken] 用于「中途停止」——实时展示时同一批请求要能一起取消。
  Future<SearchPageResult> search(SearchRequest request, {CancelToken? cancelToken}) async {
    final Response<dynamic> response = await client.post<dynamic>(
      searchPath,
      data: request.toJson(),
      cancelToken: cancelToken,
    );
    final Object? data = response.data;
    if (data == null) {
      return SearchPageResult(
        items: const <SearchResultItem>[],
        page: request.page,
        pageSize: request.pageSize,
        hasMore: false,
      );
    }
    if (data is! Map<String, dynamic>) {
      throw const ApiException(code: 'RESP_SHAPE_INVALID', message: '搜索结果返回结构不符合预期');
    }
    return SearchPageResult.fromJson(data, requestedPage: request.page);
  }

  /// 把一条结果推送到指定下载器；保存目录缺省时由后端使用下载器默认目录。
  Future<void> push({
    required String downloadUrl,
    required String downloaderId,
    String? savePath,
    String? category,
    String? mpInstanceId,
  }) =>
      client.post<void>(
        pushPath,
        data: <String, dynamic>{
          'downloadUrl': downloadUrl,
          'downloaderId': downloaderId,
          if (savePath != null && savePath.isNotEmpty) 'savePath': savePath,
          if (category != null && category.isNotEmpty) 'category': category,
          if (mpInstanceId != null && mpInstanceId.isNotEmpty) 'mpInstanceId': mpInstanceId,
        },
      );
}