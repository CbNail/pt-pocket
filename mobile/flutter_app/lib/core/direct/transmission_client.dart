import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/downloader.dart';
import '../network/url_utils.dart';
import 'qbittorrent_client.dart';

/// Transmission RPC（`/transmission/rpc`）直连客户端（Transmission 4.x 口径）。
///
/// 能力边界（与任务操作一一对应）：
/// - **支持**：任务列表、会话统计（速率 / 累计流量 / 剩余空间 / 版本）、添加种子（链接 / 文件）、
///   暂停 / 继续 / 删除、改保存路径、标签、重新校验、重新汇报、强制开始、单任务限速、
///   自动种子管理（Transmission 的 `auto-managed`）；
/// - **不支持分类**：Transmission 没有「分类」这个概念（只有标签），
///   分类调用直接报「该下载器不支持」，**不**静默写进标签冒充成功；
/// - 标签是整组覆盖语义，因此「追加 / 移除」会先取回当前标签再算新集合，避免误删已有标签。
class TransmissionClient {
  TransmissionClient(this._dio);

  final Dio _dio;

  static const Duration timeout = Duration(seconds: 12);

  /// 会话 id：首次（或会话过期）由服务端 409 下发，按下载器缓存。
  final Map<String, String> _sessionIds = <String, String>{};

  /// 任务列表要一次性取回的字段（避免逐条再查）。
  static const List<String> _fields = <String>[
    'id',
    'hashString',
    'name',
    'totalSize',
    'sizeWhenDone',
    'leftUntilDone',
    'percentDone',
    'status',
    'rateDownload',
    'rateUpload',
    'eta',
    'downloadDir',
    'labels',
    'addedDate',
    'uploadRatio',
    'trackers',
    'magnetLink',
    'downloadLimited',
    'uploadLimited',
    'downloadLimit',
    'uploadLimit',
  ];

  // ---------- 列表与统计 ----------

  Future<List<DownloaderTask>> fetchTasks(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    final Map<String, dynamic> args = await _rpc(
      config,
      credential,
      'torrent-get',
      <String, dynamic>{'fields': _fields},
      cancelToken: cancelToken,
    );
    final Object? torrents = args['torrents'];
    if (torrents is! List) {
      throw DownloaderFetchException(
        kind: DownloaderFailureKind.unparsed,
        message: '${config.name} 任务列表返回结构不符合预期（期望数组，实际为 '
            '${torrents == null ? '空' : torrents.runtimeType}）',
        target: config.baseUrl,
      );
    }
    return torrents
        .whereType<Map<String, dynamic>>()
        .map(_taskFromTransmission)
        .where((DownloaderTask task) => task.hash.isNotEmpty)
        .toList(growable: false);
  }

  /// 可选值：Transmission 只有标签与路径（**没有分类**，分类候选返回空）。
  Future<DownloaderTaskOption> fetchTaskOptions(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    final Set<String> tags = <String>{};
    final Set<String> paths = <String>{};

    final Map<String, dynamic> args = await _rpc(
      config,
      credential,
      'torrent-get',
      <String, dynamic>{'fields': <String>['labels', 'downloadDir']},
      cancelToken: cancelToken,
    );
    for (final Map<String, dynamic> torrent
        in (args['torrents'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<String, dynamic>>()) {
      tags.addAll(_strings(torrent['labels']));
      final String dir = torrent['downloadDir']?.toString() ?? '';
      if (dir.isNotEmpty) paths.add(dir);
    }
    try {
      final Map<String, dynamic> session = await _rpc(
        config,
        credential,
        'session-get',
        const <String, dynamic>{},
        cancelToken: cancelToken,
      );
      final String dir = session['download-dir']?.toString() ?? '';
      if (dir.isNotEmpty) paths.add(dir);
    } on DownloaderFetchException {
      // 会话信息取不到不影响候选值，忽略即可。
    }
    if (config.defaultSavePath.isNotEmpty) paths.add(config.defaultSavePath);

    return DownloaderTaskOption(
      categories: const <String>[],
      tags: tags.toList(growable: false)..sort(),
      paths: paths.toList(growable: false),
    );
  }

  /// 传输概览：会话统计 + 会话设置（版本 / 全局限速）+ 剩余空间。
  ///
  /// 取不到的字段保持 null（界面显示「未采集」），不用 0 冒充。
  Future<QbTransferInfo> fetchTransferInfo(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    final Map<String, dynamic> stats = await _rpc(
      config,
      credential,
      'session-stats',
      const <String, dynamic>{},
      cancelToken: cancelToken,
    );
    final Map<String, dynamic> session = await _rpc(
      config,
      credential,
      'session-get',
      const <String, dynamic>{},
      cancelToken: cancelToken,
    );

    int? freeSpace;
    try {
      final Map<String, dynamic> space = await _rpc(
        config,
        credential,
        'free-space',
        <String, dynamic>{'path': session['download-dir']?.toString() ?? ''},
        cancelToken: cancelToken,
      );
      final int size = _int(space['size-bytes']);
      if (size > 0) freeSpace = size;
    } on DownloaderFetchException {
      freeSpace = null;
    }

    return QbTransferInfo(
      downloadSpeed: _int(stats['downloadSpeed']),
      uploadSpeed: _int(stats['uploadSpeed']),
      downloadedBytes: _int(stats['downloadedBytes']),
      uploadedBytes: _int(stats['uploadedBytes']),
      version: session['version']?.toString() ?? '',
      freeSpaceBytes: freeSpace,
      downloadLimitBytes: session['speed-limit-down-enabled'] == true
          ? _int(session['speed-limit-down']) * 1024
          : 0,
      uploadLimitBytes: session['speed-limit-up-enabled'] == true
          ? _int(session['speed-limit-up']) * 1024
          : 0,
    );
  }

  // ---------- 添加种子 ----------

  /// 添加种子：逐条提交（Transmission 的 `torrent-add` 一次只收一条 filename）。
  Future<void> addTorrentLinks(
    DownloaderConfig config,
    Map<String, dynamic>? credential, {
    required List<String> links,
    List<String> tags = const <String>[],
    String savePath = '',
    bool paused = false,
  }) async {
    final List<String> valid = links
        .map((String link) => link.trim())
        .where((String link) => link.isNotEmpty)
        .toList(growable: false);
    if (valid.isEmpty) {
      throw const DownloaderFetchException(
        kind: DownloaderFailureKind.unparsed,
        message: '请至少填一条种子链接或磁力链接',
      );
    }
    for (final String link in valid) {
      await _rpc(config, credential, 'torrent-add', <String, dynamic>{
        'filename': link,
        if (tags.isNotEmpty) 'labels': tags,
        if (savePath.trim().isNotEmpty) 'download-dir': savePath.trim(),
        'paused': paused,
      });
    }
  }

  /// 添加种子文件：`metainfo` 传 base64（Transmission RPC 的规定）。
  Future<void> addTorrentFile(
    DownloaderConfig config,
    Map<String, dynamic>? credential, {
    required List<int> bytes,
    required String filename,
    List<String> tags = const <String>[],
    String savePath = '',
    bool paused = false,
  }) async {
    await _rpc(config, credential, 'torrent-add', <String, dynamic>{
      'metainfo': base64Encode(bytes),
      if (tags.isNotEmpty) 'labels': tags,
      if (savePath.trim().isNotEmpty) 'download-dir': savePath.trim(),
      'paused': paused,
    });
  }

  // ---------- 任务操作 ----------

  Future<void> pause(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
  ) =>
      _write(config, credential, 'torrent-stop', hashes);

  Future<void> resume(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
  ) =>
      _write(config, credential, 'torrent-start', hashes);

  /// 强制开始（Transmission 的「立即开始」）。
  Future<void> startNow(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
  ) =>
      _write(config, credential, 'torrent-start-now', hashes);

  Future<void> remove(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes, {
    bool deleteFiles = false,
  }) =>
      _rpc(config, credential, 'torrent-remove', <String, dynamic>{
        'ids': hashes,
        'delete-local-data': deleteFiles,
      });

  /// 重新校验。
  Future<void> recheck(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
  ) =>
      _write(config, credential, 'torrent-verify', hashes);

  /// 重新汇报 tracker。
  Future<void> reannounce(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
  ) =>
      _write(config, credential, 'torrent-reannounce', hashes);

  /// 改保存路径（Transmission 的 `location-move`）。
  Future<void> setLocation(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    String savePath,
  ) async {
    if (savePath.trim().isEmpty) {
      throw const DownloaderFetchException(
        kind: DownloaderFailureKind.unparsed,
        message: '请填写新的保存路径',
      );
    }
    await _rpc(config, credential, 'torrent-set', <String, dynamic>{
      'ids': hashes,
      'location-move': savePath.trim(),
    });
  }

  /// 设置标签（整组覆盖）；空集合会被拒绝——Transmission 不接受清空标签。
  Future<void> setLabels(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    List<String> labels,
  ) async {
    final List<String> valid =
        labels.map((String l) => l.trim()).where((String l) => l.isNotEmpty).toList(growable: false);
    if (valid.isEmpty) {
      throw DownloaderFetchException(
        kind: DownloaderFailureKind.unknown,
        message: '${config.name}：该下载器不支持把标签清空（Transmission 的标签是整组覆盖）',
      );
    }
    await _rpc(config, credential, 'torrent-set', <String, dynamic>{
      'ids': hashes,
      'labels': valid,
    });
  }

  /// 标签增改：Transmission 是整组覆盖，所以先取当前标签再算新集合。
  Future<void> setTags(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    List<String> tags, {
    String mode = 'add',
  }) async {
    final Map<String, dynamic> args = await _rpc(
      config,
      credential,
      'torrent-get',
      <String, dynamic>{
        'ids': hashes,
        'fields': <String>['hashString', 'labels'],
      },
    );
    for (final Map<String, dynamic> torrent
        in (args['torrents'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<String, dynamic>>()) {
      final String hash = torrent['hashString']?.toString() ?? '';
      if (hash.isEmpty) continue;
      final Set<String> current = _strings(torrent['labels']).toSet();
      final Set<String> next = switch (mode) {
        'remove' => current.difference(tags.toSet()),
        'set' => tags.toSet(),
        _ => current.union(tags.toSet()),
      };
      if (next.isEmpty) {
        throw DownloaderFetchException(
          kind: DownloaderFailureKind.unknown,
          message: '${config.name}：该下载器不支持把标签清空（Transmission 的标签是整组覆盖）',
        );
      }
      await _rpc(config, credential, 'torrent-set', <String, dynamic>{
        'ids': <String>[hash],
        'labels': next.toList(growable: false),
      });
    }
  }

  /// 自动种子管理（Transmission 的 `auto-managed`）。
  Future<void> setAutoManaged(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    bool enabled,
  ) =>
      _rpc(config, credential, 'torrent-set', <String, dynamic>{
        'ids': hashes,
        'auto-managed': enabled,
      });

  /// 单任务下载限速；0 表示不限（Transmission 以 KB/s 为单位）。
  Future<void> setDownloadLimit(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    int bytesPerSecond,
  ) =>
      _rpc(config, credential, 'torrent-set', <String, dynamic>{
        'ids': hashes,
        'downloadLimited': bytesPerSecond > 0,
        'downloadLimit': (bytesPerSecond / 1024).round(),
      });

  /// 单任务上传限速；0 表示不限（Transmission 以 KB/s 为单位）。
  Future<void> setUploadLimit(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    int bytesPerSecond,
  ) =>
      _rpc(config, credential, 'torrent-set', <String, dynamic>{
        'ids': hashes,
        'uploadLimited': bytesPerSecond > 0,
        'uploadLimit': (bytesPerSecond / 1024).round(),
      });

  /// 分类：Transmission 没有这个概念，明确报不支持（不写标签冒充）。
  Future<void> setCategory(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    String category,
  ) async {
    throw DownloaderFetchException(
      kind: DownloaderFailureKind.unknown,
      message: '${config.name}：该下载器不支持分类（Transmission 只有标签，请用「编辑标签」）',
    );
  }

  /// 自动种子管理是否可用（qBittorrent 没有这个概念）。
  static bool supportsAutoManaged(DownloaderKind kind) => kind == DownloaderKind.transmission;

  Future<void> _write(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    String method,
    List<String> hashes,
  ) =>
      _rpc(config, credential, method, <String, dynamic>{'ids': hashes});

  // ---------- RPC 传输 ----------

  Future<Map<String, dynamic>> _rpc(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    String method,
    Map<String, dynamic> arguments, {
    CancelToken? cancelToken,
  }) async {
    final Uri? base = UrlUtils.normalize(config.baseUrl);
    if (base == null) {
      throw const DownloaderFetchException(
        kind: DownloaderFailureKind.unparsed,
        message: '下载器地址不合法，请先修正地址',
      );
    }
    final Uri endpoint = UrlUtils.joinPath(base, '/transmission/rpc');
    final Object payload = jsonEncode(<String, dynamic>{
      'method': method,
      'arguments': arguments,
    });

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final String? sessionId = _sessionIds[config.id];
        final String? auth = _basicAuth(config, credential);
        final Response<dynamic> response = await _dio.postUri<dynamic>(
          endpoint,
          data: payload,
          cancelToken: cancelToken,
          options: Options(
            contentType: Headers.jsonContentType,
            responseType: ResponseType.json,
            headers: <String, dynamic>{
              'X-Transmission-Session-Id': ?sessionId,
              'Authorization': ?auth,
            },
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (int? status) => status != null,
          ),
        );
        final int status = response.statusCode ?? 0;
        if (status == 409) {
          final String? issued = response.headers.value('x-transmission-session-id');
          if (issued == null || issued.isEmpty || attempt > 0) {
            throw DownloaderFetchException(
              kind: DownloaderFailureKind.unknown,
              message: '${config.name} 拒绝对话（HTTP 409）：请确认地址指向 Transmission 的 RPC 端口',
              target: endpoint.toString(),
              statusCode: status,
            );
          }
          _sessionIds[config.id] = issued;
          continue;
        }
        if (status == 401 || status == 403) {
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unauthorized,
            message: '${config.name} 拒绝访问（HTTP $status）：请检查 RPC 用户名 / 密码，'
                '以及 rpc-whitelist / rpc-host-whitelist 是否允许本机访问',
            target: endpoint.toString(),
            statusCode: status,
          );
        }
        if (status < 200 || status >= 300) {
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unknown,
            message: '${config.name} 返回 HTTP $status（$method）',
            target: endpoint.toString(),
            statusCode: status,
          );
        }
        final Object? data = response.data;
        if (data is! Map<String, dynamic>) {
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unparsed,
            message: '${config.name} 返回结构不符合预期（$method）',
            target: endpoint.toString(),
          );
        }
        final String result = data['result']?.toString() ?? '';
        if (result != 'success') {
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unknown,
            message: '${config.name} 拒绝该操作：$result（$method）',
            target: endpoint.toString(),
          );
        }
        final Object? args = data['arguments'];
        return args is Map<String, dynamic> ? args : const <String, dynamic>{};
      } on DioException catch (error) {
        throw DownloaderFetchException(
          kind: DownloaderFailureKind.network,
          message: _describeNetwork(config.name, endpoint, error),
          target: endpoint.toString(),
          statusCode: error.response?.statusCode,
        );
      }
    }
    throw DownloaderFetchException(
      kind: DownloaderFailureKind.unknown,
      message: '${config.name} 的 RPC 会话未能建立',
      target: endpoint.toString(),
    );
  }

  /// HTTP Basic 认证头：没填用户名时返回 null（Transmission 允许白名单内匿名访问）。
  static String? _basicAuth(DownloaderConfig config, Map<String, dynamic>? credential) {
    final String user = config.username.trim();
    final String password = credential?['password']?.toString() ?? '';
    if (user.isEmpty && password.isEmpty) return null;
    return 'Basic ${base64Encode(utf8.encode('$user:$password'))}';
  }

  static String _describeNetwork(String name, Uri target, DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.receiveTimeout:
        return '$name 连接超时：$target 在超时内没有响应（请确认手机与下载器在同一网络、端口已开放）';
      case DioExceptionType.badCertificate:
        return '$name 证书校验失败：$target 的证书不受信任（自签名证书请改用 http 地址）';
      case DioExceptionType.connectionError:
        return '$name 无法建立连接：$target 域名解析失败或端口未开放（${error.message ?? ''}）';
      default:
        return '$name 请求失败：$target（${error.message ?? error.type.name}）';
    }
  }

  /// Transmission 的 `status` 数字 → 统一状态。
  static TaskState stateOf(Object? status) {
    final int code = status is num ? status.toInt() : -1;
    return switch (code) {
      0 => TaskState.paused, // stopped
      1 || 2 => TaskState.checking, // check queued / checking
      3 => TaskState.queued, // download queued
      4 => TaskState.downloading,
      5 || 6 => TaskState.seeding, // seed queued / seeding
      _ => TaskState.unknown,
    };
  }

  /// 把 Transmission 的任务字段映射成统一模型。
  ///
  /// 说明：Transmission **没有分类**，所以 `category` 一律留空（不把第一个标签当分类）；
  /// 标签写进 `tags`；tracker 取第一个 tracker 的 announce 地址（供「服务器筛选」）。
  static DownloaderTask taskFromTransmission(Map<String, dynamic> json) =>
      _taskFromTransmission(json);

  static DownloaderTask _taskFromTransmission(Map<String, dynamic> json) {
    final int total = _int(json['totalSize']);
    final int left = _int(json['leftUntilDone']);
    final int completed =
        total <= 0 ? 0 : (left <= 0 ? total : (total - left).clamp(0, total));
    final List<String> labels = _strings(json['labels']);
    final int eta = _int(json['eta']);

    return DownloaderTask(
      hash: json['hashString']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      sizeBytes: total,
      completedBytes: completed,
      state: stateOf(json['status']),
      downloadSpeed: _int(json['rateDownload']),
      uploadSpeed: _int(json['rateUpload']),
      etaSeconds: eta <= 0 ? -1 : eta,
      savePath: json['downloadDir']?.toString() ?? '',
      ratio: (json['uploadRatio'] as num?)?.toDouble() ?? 0,
      tags: labels,
      tracker: _trackerOf(json['trackers']),
      magnetUri: json['magnetLink']?.toString() ?? '',
      downloadLimitBytes:
          json['downloadLimited'] == true ? _int(json['downloadLimit']) * 1024 : 0,
      uploadLimitBytes: json['uploadLimited'] == true ? _int(json['uploadLimit']) * 1024 : 0,
      addedAt: _addedAt(json['addedDate']),
    );
  }

  static String _trackerOf(Object? value) {
    if (value is! List) return '';
    for (final Object? item in value) {
      if (item is Map<String, dynamic>) {
        final String announce = item['announce']?.toString().trim() ?? '';
        if (announce.isNotEmpty) return announce;
      }
    }
    return '';
  }

  static DateTime? _addedAt(Object? value) {
    if (value is num) {
      final int raw = value.toInt();
      if (raw <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(raw * 1000);
    }
    if (value is String) {
      final int? epoch = int.tryParse(value.trim());
      if (epoch != null) return _addedAt(epoch);
      return DateTime.tryParse(value.trim());
    }
    return null;
  }

  static List<String> _strings(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((Object? item) => item.toString().trim())
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static int _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }
}