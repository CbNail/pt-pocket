import 'package:dio/dio.dart';

import '../models/downloader.dart';
import '../services/downloader_api.dart';
import 'qbittorrent_client.dart';

/// 下载器数据通道：**直连优先**，NAS 后端可用时作为补充/回退。
///
/// 路由规则：
/// - qBittorrent：直接调用 WebUI（`/api/v2`）取任务、可选值、全局速度与写操作；
///   直连因「缺少账号密码 / 网络不通」失败而 NAS 后端又可用时，回退后端接口；
/// - Transmission / Aria2：本 App 尚未实现直连协议，只走后端接口
///   （后端不可用时给出明确说明，而不是显示「任务获取失败」这种没有原因的报错）。
class DownloaderGateway {
  DownloaderGateway(
    this._nasConfigured,
    this._resolveConfig,
    this._resolveCredential, {
    required this.nas,
    required this.qb,
  });

  final DownloaderApi nas;
  final QbittorrentClient qb;
  final bool Function() _nasConfigured;
  final DownloaderConfig? Function(String downloaderId) _resolveConfig;
  final Future<Map<String, dynamic>?> Function(String downloaderId) _resolveCredential;

  bool get nasAvailable => _nasConfigured();

  /// 任务列表。
  Future<List<DownloaderTask>> fetchTasks(String downloaderId, {CancelToken? cancelToken}) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    if (config.kind == DownloaderKind.qbittorrent) {
      return _directOrFallback<List<DownloaderTask>>(
        config,
        direct: () => qb.fetchTasks(config, credential: credential, cancelToken: cancelToken),
        fallback: () => nas.fetchTasks(downloaderId),
        fallbackWhen: (Object error) =>
            error is DownloaderFetchException &&
            (error.kind == DownloaderFailureKind.missingCredential ||
                error.kind == DownloaderFailureKind.network),
      );
    }
    return _nasOnly<List<DownloaderTask>>(
      config,
      () => nas.fetchTasks(downloaderId),
    );
  }

  /// 可选分类 / 标签 / 路径。
  Future<DownloaderTaskOption> fetchTaskOptions(String downloaderId) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    if (config.kind == DownloaderKind.qbittorrent) {
      return _directOrFallback<DownloaderTaskOption>(
        config,
        direct: () => qb.fetchTaskOptions(config, credential: credential),
        fallback: () => nas.fetchTaskOptions(downloaderId),
        fallbackWhen: (Object error) => error is DownloaderFetchException,
      );
    }
    return _nasOnly<DownloaderTaskOption>(
      config,
      () => nas.fetchTaskOptions(downloaderId),
    );
  }

  /// 全局传输状态（只有 qBittorrent 直连时可用；后端未提供该接口）。
  Future<QbTransferInfo?> fetchTransferInfo(String downloaderId) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    if (config.kind != DownloaderKind.qbittorrent) return null;
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    try {
      return await qb.fetchTransferInfo(config, credential: credential);
    } catch (_) {
      return null;
    }
  }

  Future<void> pause(String downloaderId, List<String> hashes) =>
      _action(downloaderId, (DownloaderConfig c, Map<String, dynamic>? cred) => qb.pause(c, cred, hashes),
          () => nas.pause(downloaderId, hashes));

  Future<void> resume(String downloaderId, List<String> hashes) =>
      _action(downloaderId, (DownloaderConfig c, Map<String, dynamic>? cred) => qb.resume(c, cred, hashes),
          () => nas.resume(downloaderId, hashes));

  Future<void> remove(String downloaderId, List<String> hashes, {bool deleteFiles = false}) => _action(
        downloaderId,
        (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.remove(c, cred, hashes, deleteFiles: deleteFiles),
        () => nas.remove(downloaderId, hashes, deleteFiles: deleteFiles),
      );

  Future<void> setCategory(String downloaderId, List<String> hashes, String category) => _action(
        downloaderId,
        (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setCategory(c, cred, hashes, category),
        () => nas.setCategory(downloaderId, hashes, category),
      );

  Future<void> setTags(
    String downloaderId,
    List<String> hashes,
    List<String> tags, {
    String mode = 'add',
  }) =>
      _action(
        downloaderId,
        (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setTags(c, cred, hashes, tags, mode: mode),
        () => nas.setTags(downloaderId, hashes, tags, mode: mode),
      );

  Future<void> setLocation(String downloaderId, List<String> hashes, String savePath) => _action(
        downloaderId,
        (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setLocation(c, cred, hashes, savePath),
        () => nas.setLocation(downloaderId, hashes, savePath),
      );

  Future<void> _action(
    String downloaderId,
    Future<void> Function(DownloaderConfig config, Map<String, dynamic>? credential) direct,
    Future<void> Function() fallback,
  ) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    if (config.kind != DownloaderKind.qbittorrent) {
      return _nasOnly<void>(config, fallback);
    }
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    return _directOrFallback<void>(
      config,
      direct: () => direct(config, credential),
      fallback: fallback,
      fallbackWhen: (Object error) =>
          error is DownloaderFetchException &&
          (error.kind == DownloaderFailureKind.missingCredential ||
              error.kind == DownloaderFailureKind.network),
    );
  }

  Future<T> _directOrFallback<T>(
    DownloaderConfig config, {
    required Future<T> Function() direct,
    required Future<T> Function() fallback,
    required bool Function(Object error) fallbackWhen,
  }) async {
    try {
      return await direct();
    } catch (error) {
      if (!nasAvailable || !fallbackWhen(error)) rethrow;
      return fallback();
    }
  }

  Future<T> _nasOnly<T>(DownloaderConfig config, Future<T> Function() action) {
    if (!nasAvailable) {
      throw DownloaderFetchException(
        kind: DownloaderFailureKind.missingCredential,
        message: '${config.name}（${config.kind.label}）需要 NAS 后端转发：'
            '本 App 目前只提供 qBittorrent 直连，请先配置 NAS 服务地址，或改用 qBittorrent',
      );
    }
    return action();
  }

  DownloaderConfig _requireConfig(String downloaderId) {
    final DownloaderConfig? config = _resolveConfig(downloaderId);
    if (config == null) {
      throw const DownloaderFetchException(
        kind: DownloaderFailureKind.unparsed,
        message: '下载器已不存在，请返回列表刷新后重试',
      );
    }
    return config;
  }
}