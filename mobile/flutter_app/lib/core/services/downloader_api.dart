import 'package:dio/dio.dart';

import '../models/downloader.dart';
import '../network/api_client.dart';
import '../network/api_exception.dart';

/// NAS 后端「下载器」接口契约（客户端侧）。
///
/// 架构约定（规格书 §7.1）：下载器账号与各引擎协议调用统一在 NAS 后端完成，
/// 移动端只通过版本化接口取任务列表与下发操作，避免把第三方协议逻辑下沉到页面。
///
/// 契约：
/// - `GET  /api/v1/downloaders/{id}/tasks` → 归一化任务数组；
/// - `GET  /api/v1/downloaders/{id}/task-options` → `{categories, tags, paths}`；
/// - `POST /api/v1/downloaders/{id}/tasks/pause`  body `{hashes:[...]}`；
/// - `POST /api/v1/downloaders/{id}/tasks/resume` body `{hashes:[...]}`；
/// - `POST /api/v1/downloaders/{id}/tasks/remove` body `{hashes:[...], deleteFiles:bool}`；
/// - `POST /api/v1/downloaders/{id}/tasks/category` body `{hashes:[...], category}`；
/// - `POST /api/v1/downloaders/{id}/tasks/tags`     body `{hashes:[...], tags:[...], mode}`；
/// - `POST /api/v1/downloaders/{id}/tasks/location` body `{hashes:[...], savePath}`。
///
/// `mode` 取 `add`（默认，追加标签）/ `remove`（移除这些标签）/ `set`（覆盖为这些标签）。
class DownloaderApi {
  DownloaderApi({required this.client});

  final ApiClient client;

  static const String prefix = '/api/v1/downloaders';

  /// 拉取某下载器的任务列表。
  Future<List<DownloaderTask>> fetchTasks(String downloaderId) async {
    final Response<dynamic> response =
        await client.get<dynamic>('$prefix/$downloaderId/tasks');
    final Object? data = response.data;
    if (data == null) return const <DownloaderTask>[];
    if (data is! List) {
      // 明确报错而不是静默返回空列表，避免把结构问题伪装成"没有任务"。
      throw const ApiException(code: 'RESP_SHAPE_INVALID', message: '下载器任务返回结构不符合预期');
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map(DownloaderTask.fromJson)
        .toList(growable: false);
  }

  Future<void> pause(String downloaderId, List<String> hashes) =>
      _taskAction(downloaderId, 'pause', hashes);

  Future<void> resume(String downloaderId, List<String> hashes) =>
      _taskAction(downloaderId, 'resume', hashes);

  /// 移除任务；[deleteFiles] 为真时同时删除已下载数据。
  Future<void> remove(String downloaderId, List<String> hashes, {bool deleteFiles = false}) =>
      client.post<void>(
        '$prefix/$downloaderId/tasks/remove',
        data: <String, dynamic>{'hashes': hashes, 'deleteFiles': deleteFiles},
      );

  /// 可选分类 / 标签 / 路径；后端未实现该接口时按空列表处理，不影响任务列表。
  Future<DownloaderTaskOption> fetchTaskOptions(String downloaderId) async {
    final Response<dynamic> response =
        await client.get<dynamic>('$prefix/$downloaderId/task-options');
    final Object? data = response.data;
    if (data is Map<String, dynamic>) return DownloaderTaskOption.fromJson(data);
    return const DownloaderTaskOption();
  }

  /// 更改分类（空串表示清除分类）。
  Future<void> setCategory(String downloaderId, List<String> hashes, String category) =>
      client.post<void>(
        '$prefix/$downloaderId/tasks/category',
        data: <String, dynamic>{'hashes': hashes, 'category': category},
      );

  /// 标签操作；[mode] 见类注释。
  Future<void> setTags(
    String downloaderId,
    List<String> hashes,
    List<String> tags, {
    String mode = 'add',
  }) =>
      client.post<void>(
        '$prefix/$downloaderId/tasks/tags',
        data: <String, dynamic>{'hashes': hashes, 'tags': tags, 'mode': mode},
      );

  /// 更改保存路径。
  Future<void> setLocation(String downloaderId, List<String> hashes, String savePath) =>
      client.post<void>(
        '$prefix/$downloaderId/tasks/location',
        data: <String, dynamic>{'hashes': hashes, 'savePath': savePath},
      );

  Future<void> _taskAction(String downloaderId, String action, List<String> hashes) =>
      client.post<void>(
        '$prefix/$downloaderId/tasks/$action',
        data: <String, dynamic>{'hashes': hashes},
      );
}