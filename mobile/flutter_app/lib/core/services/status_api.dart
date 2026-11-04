import 'package:dio/dio.dart';

import '../models/notify_settings.dart';
import '../models/status_models.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';

/// 个人数据与统计接口（需求 2：输出 PT 我的数据（历程、数据统计））。
///
/// 契约：`GET /api/v1/profile?siteIds=...` → `{ sites: [...], generatedAt, notice }`。
class ProfileApi {
  ProfileApi({required this.client});

  final ApiClient client;

  static const String path = '/api/v1/profile';

  Future<PtDataSnapshot> fetch({List<String> siteIds = const <String>[]}) async {
    final Response<dynamic> response = await client.get<dynamic>(
      path,
      query: siteIds.isEmpty ? null : <String, dynamic>{'siteIds': siteIds.join(',')},
    );
    final Object? data = response.data;
    if (data == null) return const PtDataSnapshot(sites: <SiteStats>[]);
    if (data is! Map<String, dynamic>) {
      throw const ApiException(code: 'RESP_SHAPE_INVALID', message: '个人数据返回结构不符合预期');
    }
    return PtDataSnapshot.fromJson(data);
  }
}

/// 站点数据面板接口（需求 4：站点页的刷新与四态呈现）。
///
/// 契约：
/// - 站点统计字段复用 `GET /api/v1/profile?siteIds=...`（与个人数据同一份口径，
///   避免同一批数据两套字段）；
/// - `POST /api/v1/sites/{siteId}/refresh` → 单站刷新；
/// - `POST /api/v1/sites/refresh` body `{siteIds?}` → 批量刷新（为空表示全部启用站点）。
///
/// 抓取站点页面由 NAS 后端适配器完成；移动端只触发并消费结果。
class SiteStatsApi {
  SiteStatsApi({required this.client});

  final ApiClient client;

  static const String refreshAllPath = '/api/v1/sites/refresh';

  Future<void> refreshSite(String siteId) =>
      client.post<void>('/api/v1/sites/$siteId/refresh');

  Future<void> refreshAll({List<String> siteIds = const <String>[]}) => client.post<void>(
        refreshAllPath,
        data: <String, dynamic>{
          if (siteIds.isNotEmpty) 'siteIds': siteIds,
        },
      );
}

/// PT 监护室接口（需求 6：各 PT 站点是否病危、站庆等）。
///
/// 契约：`GET /api/v1/monitor/events?limit=N` → `{ items: [...] }` 或数组。
class MonitorApi {
  MonitorApi({required this.client});

  final ApiClient client;

  static const String path = '/api/v1/monitor/events';

  Future<List<MonitorEvent>> fetchEvents({int limit = 50}) async {
    final Response<dynamic> response = await client.get<dynamic>(
      path,
      query: <String, dynamic>{'limit': limit},
    );
    final Object? data = response.data;
    final Object? raw = data is Map<String, dynamic> ? (data['items'] ?? data['events']) : data;
    if (raw == null) return const <MonitorEvent>[];
    if (raw is! List) {
      throw const ApiException(code: 'RESP_SHAPE_INVALID', message: '监护事件返回结构不符合预期');
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(MonitorEvent.fromJson)
        .toList(growable: false);
  }
}

/// 签到接口（需求 10：一键签到，未成功站点自动定时补签到）。
///
/// 契约：
/// - `POST /api/v1/signin/run` body `{siteIds?}` → 批量签到结果；
/// - `POST /api/v1/sites/{siteId}/signin` → 单站签到结果；
/// - `GET  /api/v1/signin/records?limit=N` → 最近签到记录。
///
/// 定时补签由 NAS 后端 worker 调度，移动端只负责触发与查看结果。
class SignInApi {
  SignInApi({required this.client});

  final ApiClient client;

  static const String runPath = '/api/v1/signin/run';
  static const String recordsPath = '/api/v1/signin/records';

  /// 批量签到。[mode] 区分「签到 + 模拟登录 / 仅签到 / 仅模拟登录」，
  /// 与参考实现的「签到站点 + 仅模拟登录站点」两类口径一致。
  Future<SignInRunResult> runAll({
    List<String> siteIds = const <String>[],
    SignInMode mode = SignInMode.both,
  }) async {
    final Response<dynamic> response = await client.post<dynamic>(
      runPath,
      data: <String, dynamic>{
        if (siteIds.isNotEmpty) 'siteIds': siteIds,
        'mode': mode.apiValue,
      },
    );
    return _parseResult(response.data);
  }

  Future<SignInRunResult> runSite(String siteId, {SignInMode mode = SignInMode.both}) async {
    final Response<dynamic> response = await client.post<dynamic>(
      '/api/v1/sites/$siteId/signin',
      data: <String, dynamic>{'mode': mode.apiValue},
    );
    return _parseResult(response.data);
  }

  Future<List<SignInRecord>> fetchRecords({int limit = 20}) async {
    final Response<dynamic> response = await client.get<dynamic>(
      recordsPath,
      query: <String, dynamic>{'limit': limit},
    );
    final Object? data = response.data;
    final Object? raw = data is Map<String, dynamic> ? (data['items'] ?? data['records']) : data;
    if (raw == null) return const <SignInRecord>[];
    if (raw is! List) {
      throw const ApiException(code: 'RESP_SHAPE_INVALID', message: '签到记录返回结构不符合预期');
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(SignInRecord.fromJson)
        .toList(growable: false);
  }

  SignInRunResult _parseResult(Object? data) {
    if (data == null) return const SignInRunResult(records: <SignInRecord>[]);
    if (data is Map<String, dynamic>) return SignInRunResult.fromJson(data);
    if (data is List) {
      return SignInRunResult(
        records: data
            .whereType<Map<String, dynamic>>()
            .map(SignInRecord.fromJson)
            .toList(growable: false),
      );
    }
    throw const ApiException(code: 'RESP_SHAPE_INVALID', message: '签到结果返回结构不符合预期');
  }
}

/// 推送通道接口（需求 14）。
///
/// 契约：`POST /api/v1/notify/test` body `{channel}` → 由 NAS 后端实际发送一条测试消息。
class NotifyApi {
  NotifyApi({required this.client});

  final ApiClient client;

  static const String testPath = '/api/v1/notify/test';

  Future<void> sendTest(NotifyChannel channel) => client.post<void>(
        testPath,
        data: <String, dynamic>{'channel': channel.name},
      );
}