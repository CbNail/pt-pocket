import 'package:dio/dio.dart';

import '../models/downloader.dart';
import '../network/api_exception.dart';
import '../services/downloader_api.dart';
import 'qbittorrent_client.dart';
import 'transmission_client.dart';

/// 下载器数据通道：**直连优先**，NAS 后端可用时作为补充/回退。
///
/// 路由规则：
/// - **qBittorrent**：直连 WebUI（`/api/v2`）取任务 / 可选值 / 传输概览与全部写操作；
/// - **Transmission**：直连 RPC（`/transmission/rpc`）取任务 / 统计与写操作；
///   Transmission 没有的能力（分类、强制继续开关）直接报「该下载器不支持」；
/// - **Aria2 等其余引擎**：本 App 尚未实现直连协议，只走后端接口，
///   后端也未配置时给出明确说明，而不是显示「任务获取失败」这种没有原因的报错；
/// - 直连因「缺少账号密码 / 网络不通」失败而 NAS 后端又可用时，回退后端接口。
class DownloaderGateway {
  DownloaderGateway(
    this._nasConfigured,
    this._resolveConfig,
    this._resolveCredential, {
    required this.nas,
    required this.qb,
    required this.tr,
  });

  final DownloaderApi nas;
  final QbittorrentClient qb;
  final TransmissionClient tr;
  final bool Function() _nasConfigured;
  final DownloaderConfig? Function(String downloaderId) _resolveConfig;
  final Future<Map<String, dynamic>?> Function(String downloaderId) _resolveCredential;

  bool get nasAvailable => _nasConfigured();

  /// 直连失败后可以回退后端的两类原因：本机缺凭据、网络不通。
  static bool _fallbackWhen(Object error) =>
      error is DownloaderFetchException &&
      (error.kind == DownloaderFailureKind.missingCredential ||
          error.kind == DownloaderFailureKind.network);

  // ---------- 读取 ----------

  /// 任务列表。
  Future<List<DownloaderTask>> fetchTasks(String downloaderId, {CancelToken? cancelToken}) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    switch (config.kind) {
      case DownloaderKind.qbittorrent:
        return _directOrFallback<List<DownloaderTask>>(
          direct: () => qb.fetchTasks(config, credential: credential, cancelToken: cancelToken),
          fallback: () => nas.fetchTasks(downloaderId),
        );
      case DownloaderKind.transmission:
        return _directOrFallback<List<DownloaderTask>>(
          direct: () => tr.fetchTasks(config, credential: credential, cancelToken: cancelToken),
          fallback: () => nas.fetchTasks(downloaderId),
        );
      case DownloaderKind.aria2:
        return _nasOnly<List<DownloaderTask>>(config, () => nas.fetchTasks(downloaderId));
    }
  }

  /// 可选分类 / 标签 / 路径。
  Future<DownloaderTaskOption> fetchTaskOptions(String downloaderId) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    switch (config.kind) {
      case DownloaderKind.qbittorrent:
        return _directOrFallback<DownloaderTaskOption>(
          direct: () => qb.fetchTaskOptions(config, credential: credential),
          fallback: () => nas.fetchTaskOptions(downloaderId),
          fallbackWhen: (Object error) => error is DownloaderFetchException,
        );
      case DownloaderKind.transmission:
        return _directOrFallback<DownloaderTaskOption>(
          direct: () => tr.fetchTaskOptions(config, credential: credential),
          fallback: () => nas.fetchTaskOptions(downloaderId),
          fallbackWhen: (Object error) => error is DownloaderFetchException,
        );
      case DownloaderKind.aria2:
        return _nasOnly<DownloaderTaskOption>(config, () => nas.fetchTaskOptions(downloaderId));
    }
  }

  /// 传输概览（速率 / 累计流量 / 限速 / 剩余空间 / 版本）；Aria2 暂不提供。
  Future<QbTransferInfo?> fetchTransferInfo(String downloaderId) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    if (config.kind == DownloaderKind.aria2) return null;
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    try {
      return config.kind == DownloaderKind.transmission
          ? await tr.fetchTransferInfo(config, credential: credential)
          : await qb.fetchTransferInfo(config, credential: credential);
    } catch (_) {
      // 概览属于装饰性数据：取不到就让界面显示「未采集」，不打断任务列表。
      return null;
    }
  }

  /// 单个下载器的聚合统计：任务列表 + 引擎级状态（速率 / 限速 / 剩余空间 / 版本）。
  ///
  /// 失败不抛异常，而是把原因放进 [DownloaderStats.failureMessage]：
  /// 列表页要把「取不到」显示成原因，而不是画成一堆 0。
  Future<DownloaderStats> fetchStats(String downloaderId) async {
    try {
      final List<DownloaderTask> tasks = await fetchTasks(downloaderId);
      final QbTransferInfo? transfer = await fetchTransferInfo(downloaderId);
      return DownloaderStats.fromTasks(
        tasks,
        downloadSpeed: transfer?.downloadSpeed,
        uploadSpeed: transfer?.uploadSpeed,
        freeSpaceBytes: transfer?.freeSpaceBytes,
        downloadLimitBytes: transfer?.downloadLimitBytes,
        uploadLimitBytes: transfer?.uploadLimitBytes,
        version: transfer?.version ?? '',
      );
    } on DownloaderFetchException catch (error) {
      return DownloaderStats(failureMessage: '${error.kind.label}：${error.message}');
    } on ApiException catch (error) {
      return DownloaderStats(failureMessage: error.message);
    } catch (error) {
      return DownloaderStats(failureMessage: '$error');
    }
  }

  // ---------- 基础写操作 ----------

  Future<void> pause(String downloaderId, List<String> hashes) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) => qb.pause(c, cred, hashes),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) => tr.pause(c, cred, hashes),
        fallback: () => nas.pause(downloaderId, hashes),
      );

  Future<void> resume(String downloaderId, List<String> hashes) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) => qb.resume(c, cred, hashes),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) => tr.resume(c, cred, hashes),
        fallback: () => nas.resume(downloaderId, hashes),
      );

  Future<void> remove(String downloaderId, List<String> hashes, {bool deleteFiles = false}) =>
      _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.remove(c, cred, hashes, deleteFiles: deleteFiles),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            tr.remove(c, cred, hashes, deleteFiles: deleteFiles),
        fallback: () => nas.remove(downloaderId, hashes, deleteFiles: deleteFiles),
      );

  Future<void> setCategory(String downloaderId, List<String> hashes, String category) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setCategory(c, cred, hashes, category),
        // Transmission 没有分类：直接报「该下载器不支持」，不做标签代替。
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            tr.setCategory(c, cred, hashes, category),
        fallback: () => nas.setCategory(downloaderId, hashes, category),
      );

  Future<void> setTags(
    String downloaderId,
    List<String> hashes,
    List<String> tags, {
    String mode = 'add',
  }) =>
      _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setTags(c, cred, hashes, tags, mode: mode),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            tr.setTags(c, cred, hashes, tags, mode: mode),
        fallback: () => nas.setTags(downloaderId, hashes, tags, mode: mode),
      );

  Future<void> setLocation(String downloaderId, List<String> hashes, String savePath) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setLocation(c, cred, hashes, savePath),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            tr.setLocation(c, cred, hashes, savePath),
        fallback: () => nas.setLocation(downloaderId, hashes, savePath),
      );

  // ---------- 添加种子与单任务高级操作 ----------

  Future<void> addTorrentLinks(
    String downloaderId, {
    required List<String> links,
    String category = '',
    List<String> tags = const <String>[],
    String savePath = '',
    bool paused = false,
  }) =>
      _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) => qb.addTorrentLinks(
          c,
          cred,
          links: links,
          category: category,
          tags: tags,
          savePath: savePath,
          paused: paused,
        ),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) => tr.addTorrentLinks(
          c,
          cred,
          links: links,
          tags: tags,
          savePath: savePath,
          paused: paused,
        ),
        fallback: () => _unsupportedAdd(downloaderId),
      );

  Future<void> addTorrentFile(
    String downloaderId, {
    required List<int> bytes,
    required String filename,
    String category = '',
    List<String> tags = const <String>[],
    String savePath = '',
    bool paused = false,
  }) =>
      _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) => qb.addTorrentFile(
          c,
          cred,
          bytes: bytes,
          filename: filename,
          category: category,
          tags: tags,
          savePath: savePath,
          paused: paused,
        ),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) => tr.addTorrentFile(
          c,
          cred,
          bytes: bytes,
          filename: filename,
          tags: tags,
          savePath: savePath,
          paused: paused,
        ),
        fallback: () => _unsupportedAdd(downloaderId),
      );

  Future<void> recheck(String downloaderId, List<String> hashes) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) => qb.recheck(c, cred, hashes),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) => tr.recheck(c, cred, hashes),
        fallback: () => _unsupportedAction(downloaderId, '重新校验', 'NAS 后端接口未提供该操作'),
      );

  Future<void> reannounce(String downloaderId, List<String> hashes) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) => qb.reannounce(c, cred, hashes),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) => tr.reannounce(c, cred, hashes),
        fallback: () => _unsupportedAction(downloaderId, '重新汇报', 'NAS 后端接口未提供该操作'),
      );

  Future<void> setForceStart(String downloaderId, List<String> hashes, bool enabled) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setForceStart(c, cred, hashes, enabled),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) => enabled
            ? tr.startNow(c, cred, hashes)
            : Future<void>.error(DownloaderFetchException(
                kind: DownloaderFailureKind.unknown,
                message: '${c.name}：该下载器不支持关闭「强制继续」（Transmission 用暂停 / 继续控制）',
              )),
        fallback: () => _unsupportedAction(downloaderId, '强制继续', 'NAS 后端接口未提供该操作'),
      );

  Future<void> setDownloadLimit(String downloaderId, List<String> hashes, int bytesPerSecond) =>
      _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setDownloadLimit(c, cred, hashes, bytesPerSecond),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            tr.setDownloadLimit(c, cred, hashes, bytesPerSecond),
        fallback: () => _unsupportedAction(downloaderId, '下载限速', 'NAS 后端接口未提供该操作'),
      );

  Future<void> setUploadLimit(String downloaderId, List<String> hashes, int bytesPerSecond) =>
      _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            qb.setUploadLimit(c, cred, hashes, bytesPerSecond),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            tr.setUploadLimit(c, cred, hashes, bytesPerSecond),
        fallback: () => _unsupportedAction(downloaderId, '上传限速', 'NAS 后端接口未提供该操作'),
      );

  /// 自动种子管理：Transmission 有 `auto-managed`，qBittorrent 没有（靠队列与优先级）。
  Future<void> setAutoManaged(String downloaderId, List<String> hashes, bool enabled) => _dispatch(
        downloaderId,
        qb: (DownloaderConfig c, Map<String, dynamic>? cred) => Future<void>.error(
          DownloaderFetchException(
            kind: DownloaderFailureKind.unknown,
            message: '${c.name}：该下载器不支持「自动种子管理」（qBittorrent 用队列与优先级管理）',
          ),
        ),
        tr: (DownloaderConfig c, Map<String, dynamic>? cred) =>
            tr.setAutoManaged(c, cred, hashes, enabled),
        fallback: () => _unsupportedAction(downloaderId, '自动种子管理', 'NAS 后端接口未提供该操作'),
      );

  /// 该引擎是否支持「自动种子管理」（菜单据此决定是否显示该项）。
  static bool supportsAutoManaged(DownloaderKind kind) =>
      TransmissionClient.supportsAutoManaged(kind);

  // ---------- 内部 ----------

  Future<void> _unsupportedAdd(String downloaderId) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    throw _unsupported(config, '添加种子', '本 App 直连只支持 qBittorrent 与 Transmission');
  }

  Future<void> _unsupportedAction(String downloaderId, String what, String reason) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    throw _unsupported(config, what, reason);
  }

  static DownloaderFetchException _unsupported(
    DownloaderConfig config,
    String what,
    String reason,
  ) =>
      DownloaderFetchException(
        kind: DownloaderFailureKind.unknown,
        message: '${config.name}（${config.kind.label}）$what：该下载器不支持（$reason）',
      );

  /// 把一组引擎动作分发到对应直连客户端；Aria2 走 NAS 后端。
  Future<void> _dispatch(
    String downloaderId, {
    required Future<void> Function(DownloaderConfig config, Map<String, dynamic>? credential) qb,
    required Future<void> Function(DownloaderConfig config, Map<String, dynamic>? credential) tr,
    required Future<void> Function() fallback,
  }) async {
    final DownloaderConfig config = _requireConfig(downloaderId);
    if (config.kind == DownloaderKind.aria2) return _nasOnly<void>(config, fallback);
    final Map<String, dynamic>? credential = await _resolveCredential(downloaderId);
    final Future<void> Function(DownloaderConfig, Map<String, dynamic>?) direct =
        config.kind == DownloaderKind.transmission ? tr : qb;
    return _directOrFallback<void>(
      direct: () => direct(config, credential),
      fallback: fallback,
      fallbackWhen: _fallbackWhen,
    );
  }

  Future<T> _directOrFallback<T>({
    required Future<T> Function() direct,
    required Future<T> Function() fallback,
    bool Function(Object error) fallbackWhen = _fallbackWhen,
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
            '本 App 的直连只支持 qBittorrent 与 Transmission，请先配置 NAS 服务地址，'
            '或改用这两种下载器',
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