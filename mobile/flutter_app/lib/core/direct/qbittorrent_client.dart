import 'package:dio/dio.dart';

import '../models/downloader.dart';
import '../network/url_utils.dart';

/// 下载器直连失败分类：界面据此给出可执行提示（密码错 / 白名单 / 网络不通…）。
enum DownloaderFailureKind {
  missingCredential('缺少账号密码'),
  unauthorized('登录被拒绝'),
  network('地址不可达'),
  unparsed('返回结构异常'),
  unknown('未知失败');

  const DownloaderFailureKind(this.label);

  final String label;
}

/// 下载器直连异常。
class DownloaderFetchException implements Exception {
  const DownloaderFetchException({
    required this.kind,
    required this.message,
    this.target = '',
    this.statusCode,
  });

  final DownloaderFailureKind kind;
  final String message;
  final String target;
  final int? statusCode;

  @override
  String toString() => message;
}

/// qBittorrent 会话（登录后的 SID 与版本）。
class QbSession {
  const QbSession({required this.sid, required this.version, required this.loggedInAt});

  final String sid;
  final String version;
  final DateTime loggedInAt;

  bool isExpired(Duration ttl, DateTime now) => now.difference(loggedInAt) >= ttl;
}

/// 会话缓存（内存）：同一应用会话内避免每次请求都重新登录。
class QbSessionStore {
  final Map<String, QbSession> _sessions = <String, QbSession>{};

  static const Duration ttl = Duration(minutes: 20);

  QbSession? get(String downloaderId, {DateTime? now}) {
    final QbSession? session = _sessions[downloaderId];
    if (session == null) return null;
    if (session.isExpired(ttl, now ?? DateTime.now())) return null;
    return session;
  }

  void put(String downloaderId, QbSession session) => _sessions[downloaderId] = session;

  void clear(String downloaderId) => _sessions.remove(downloaderId);
}

/// qBittorrent 全局传输状态（任务页头部展示，参考客户端顶部速度条）。
class QbTransferInfo {
  const QbTransferInfo({
    this.downloadSpeed = 0,
    this.uploadSpeed = 0,
    this.downloadedBytes = 0,
    this.uploadedBytes = 0,
    this.version = '',
    this.freeSpaceBytes,
    this.downloadLimitBytes,
    this.uploadLimitBytes,
  });

  final int downloadSpeed;
  final int uploadSpeed;
  final int downloadedBytes;
  final int uploadedBytes;
  final String version;

  /// 剩余磁盘空间（字节）；null 表示引擎未返回（界面显示「未采集」）。
  final int? freeSpaceBytes;

  /// 全局下载 / 上传限速（字节/秒）；0 表示不限，null 表示未采集。
  final int? downloadLimitBytes;
  final int? uploadLimitBytes;
}

/// qBittorrent WebUI API（`/api/v2`）直连客户端。
///
/// 为什么直连：下载器地址是手机在内网直连的地址（NAS 后端不可用时也能用），
/// 参考实现（PT-depiler 的「我的下载器」、Bit Control 之类的客户端）同样直连
/// WebUI 接口取任务列表。产出模型与后端接口一致（[DownloaderTask]），
/// 因此页面无需区分数据来源。
class QbittorrentClient {
  QbittorrentClient(this._dio, {QbSessionStore? sessions})
      : _sessions = sessions ?? QbSessionStore();

  final Dio _dio;
  final QbSessionStore _sessions;

  static const Duration timeout = Duration(seconds: 12);
  static const String _apiPrefix = '/api/v2';

  /// 拉取任务列表。
  Future<List<DownloaderTask>> fetchTasks(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    final List<dynamic> raw = await _getList(
      config,
      credential,
      '/torrents/info',
      cancelToken: cancelToken,
    );
    return raw
        .whereType<Map<String, dynamic>>()
        .map(parseTorrentJson)
        .where((DownloaderTask task) => task.hash.isNotEmpty)
        .toList(growable: false);
  }

  /// 拉取可选分类 / 标签 / 保存路径。
  Future<DownloaderTaskOption> fetchTaskOptions(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    final Set<String> categories = <String>{};
    final Set<String> tags = <String>{};
    final Set<String> paths = <String>{};

    final Object? categoriesRaw = await _getJson(
      config,
      credential,
      '/torrents/categories',
      cancelToken: cancelToken,
      tolerateErrors: true,
    );
    if (categoriesRaw is Map<String, dynamic>) {
      for (final MapEntry<String, dynamic> entry in categoriesRaw.entries) {
        categories.add(entry.key);
        final Object? value = entry.value;
        if (value is Map<String, dynamic>) {
          final String path = value['savePath']?.toString() ?? '';
          if (path.isNotEmpty) paths.add(path);
        }
      }
    }

    final Object? tagsRaw = await _getJson(
      config,
      credential,
      '/torrents/tags',
      cancelToken: cancelToken,
      tolerateErrors: true,
    );
    if (tagsRaw is List) {
      for (final Object? item in tagsRaw) {
        final String value = item?.toString().trim() ?? '';
        if (value.isNotEmpty) tags.add(value);
      }
    }

    final Object? defaultPathRaw = await _getJson(
      config,
      credential,
      '/app/defaultSavePath',
      cancelToken: cancelToken,
      tolerateErrors: true,
    );
    if (defaultPathRaw is String && defaultPathRaw.trim().isNotEmpty) {
      paths.add(defaultPathRaw.trim());
    }

    if (config.defaultSavePath.isNotEmpty) paths.add(config.defaultSavePath);

    return DownloaderTaskOption(
      categories: categories.toList(growable: false)..sort(),
      tags: tags.toList(growable: false)..sort(),
      paths: paths.toList(growable: false),
    );
  }

  /// 全局传输状态（速度 / 累计流量 / 版本），下载器页头部展示。
  Future<QbTransferInfo> fetchTransferInfo(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    final Object? info = await _getJson(
      config,
      credential,
      '/transfer/info',
      cancelToken: cancelToken,
      tolerateErrors: true,
    );
    final Object? versionRaw = await _getJson(
      config,
      credential,
      '/app/version',
      cancelToken: cancelToken,
      tolerateErrors: true,
    );
    // 剩余空间与全局限速只在 `server_state` 里（`/transfer/info` 不含这两个字段）。
    final Object? mainDataRaw = await _getJson(
      config,
      credential,
      '/sync/maindata',
      cancelToken: cancelToken,
      tolerateErrors: true,
    );
    final Map<String, dynamic> map =
        info is Map<String, dynamic> ? info : const <String, dynamic>{};
    final Map<String, dynamic> serverState =
        mainDataRaw is Map<String, dynamic> && mainDataRaw['server_state'] is Map<String, dynamic>
            ? mainDataRaw['server_state'] as Map<String, dynamic>
            : const <String, dynamic>{};
    return QbTransferInfo(
      downloadSpeed: _int(map['dl_info_speed']),
      uploadSpeed: _int(map['up_info_speed']),
      downloadedBytes: _int(map['dl_info_data']),
      uploadedBytes: _int(map['up_info_data']),
      version: versionRaw is String ? versionRaw.trim() : '',
      freeSpaceBytes: _intOrNull(serverState['free_space_on_disk']),
      downloadLimitBytes:
          _intOrNull(serverState['dl_rate_limit']) ?? _intOrNull(map['dl_rate_limit']),
      uploadLimitBytes:
          _intOrNull(serverState['up_rate_limit']) ?? _intOrNull(map['up_rate_limit']),
    );
  }

  /// 暂停 / 继续 / 删除 / 分类 / 标签 / 保存路径等写操作。
  Future<void> pause(DownloaderConfig config, Map<String, dynamic>? credential, List<String> hashes) =>
      _postForm(config, credential, '/torrents/pause', <String, String>{'hashes': _join(hashes)});

  Future<void> resume(DownloaderConfig config, Map<String, dynamic>? credential, List<String> hashes) =>
      _postForm(config, credential, '/torrents/resume', <String, String>{'hashes': _join(hashes)});

  Future<void> remove(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes, {
    bool deleteFiles = false,
  }) =>
      _postForm(config, credential, '/torrents/delete', <String, String>{
        'hashes': _join(hashes),
        'deleteFiles': deleteFiles ? 'true' : 'false',
      });

  Future<void> setCategory(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    String category,
  ) =>
      _postForm(config, credential, '/torrents/setCategory', <String, String>{
        'hashes': _join(hashes),
        'category': category,
      });

  Future<void> setTags(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    List<String> tags, {
    String mode = 'add',
  }) async {
    final String path = switch (mode) {
      'remove' => '/torrents/removeTags',
      'set' => '/torrents/addTags',
      _ => '/torrents/addTags',
    };
    if (mode == 'set') {
      await _postForm(config, credential, '/torrents/removeTags', <String, String>{
        'hashes': _join(hashes),
      });
    }
    await _postForm(config, credential, path, <String, String>{
      'hashes': _join(hashes),
      'tags': tags.where((String t) => t.trim().isNotEmpty).join(','),
    });
  }

  Future<void> setLocation(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    String savePath,
  ) =>
      _postForm(config, credential, '/torrents/setLocation', <String, String>{
        'hashes': _join(hashes),
        'location': savePath,
      });

  // ---------- 添加种子与单任务高级操作 ----------

  /// 添加种子：多条链接 / 磁力用换行一次提交（qBittorrent 的 `urls` 字段）。
  Future<void> addTorrentLinks(
    DownloaderConfig config,
    Map<String, dynamic>? credential, {
    required List<String> links,
    String category = '',
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
    await _postForm(config, credential, '/torrents/add', <String, String>{
      'urls': valid.join('\n'),
      if (category.trim().isNotEmpty) 'category': category.trim(),
      if (tags.isNotEmpty) 'tags': tags.where((String t) => t.trim().isNotEmpty).join(','),
      if (savePath.trim().isNotEmpty) 'savepath': savePath.trim(),
      'paused': paused ? 'true' : 'false',
    });
  }

  /// 添加种子文件（`.torrent` 字节流，multipart 上传）。
  Future<void> addTorrentFile(
    DownloaderConfig config,
    Map<String, dynamic>? credential, {
    required List<int> bytes,
    required String filename,
    String category = '',
    List<String> tags = const <String>[],
    String savePath = '',
    bool paused = false,
  }) async {
    final FormData form = FormData.fromMap(<String, dynamic>{
      'torrents': MultipartFile.fromBytes(bytes, filename: filename),
      if (category.trim().isNotEmpty) 'category': category.trim(),
      if (tags.isNotEmpty) 'tags': tags.where((String t) => t.trim().isNotEmpty).join(','),
      if (savePath.trim().isNotEmpty) 'savepath': savePath.trim(),
      'paused': paused ? 'true' : 'false',
    });
    await _postMultipart(config, credential, '/torrents/add', form);
  }

  /// 重新校验。
  Future<void> recheck(DownloaderConfig config, Map<String, dynamic>? credential, List<String> hashes) =>
      _postForm(config, credential, '/torrents/recheck', <String, String>{'hashes': _join(hashes)});

  /// 重新汇报 tracker。
  Future<void> reannounce(DownloaderConfig config, Map<String, dynamic>? credential, List<String> hashes) =>
      _postForm(config, credential, '/torrents/reannounce', <String, String>{'hashes': _join(hashes)});

  /// 强制继续开关。
  Future<void> setForceStart(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    bool enabled,
  ) =>
      _postForm(config, credential, '/torrents/setForceStart', <String, String>{
        'hashes': _join(hashes),
        'value': enabled ? 'true' : 'false',
      });

  /// 单任务下载限速（字节/秒）；0 表示不限。
  Future<void> setDownloadLimit(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    int bytesPerSecond,
  ) =>
      _postForm(config, credential, '/torrents/setDownloadLimit', <String, String>{
        'hashes': _join(hashes),
        'limit': '${bytesPerSecond < 0 ? 0 : bytesPerSecond}',
      });

  /// 单任务上传限速（字节/秒）；0 表示不限。
  Future<void> setUploadLimit(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    List<String> hashes,
    int bytesPerSecond,
  ) =>
      _postForm(config, credential, '/torrents/setUploadLimit', <String, String>{
        'hashes': _join(hashes),
        'limit': '${bytesPerSecond < 0 ? 0 : bytesPerSecond}',
      });

  /// multipart 表单提交（添加种子文件用；文本表单走 [_postForm]）。
  Future<void> _postMultipart(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    String path,
    FormData data,
  ) async {
    await _withSession<void>(
      config,
      credential,
      (QbSession session) async {
        final Response<String> response = await _dio.postUri<String>(
          UrlUtils.joinPath(UrlUtils.normalize(config.baseUrl)!, '$_apiPrefix$path'),
          data: data,
          options: Options(
            responseType: ResponseType.plain,
            headers: <String, dynamic>{'Cookie': 'SID=${session.sid}'},
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (int? status) => status != null,
          ),
        );
        final int status = response.statusCode ?? 0;
        if (status == 401 || status == 403) {
          throw _SessionExpired(status);
        }
        if (status < 200 || status >= 300) {
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unknown,
            message: '${config.name} 添加种子失败（HTTP $status）',
            target: path,
            statusCode: status,
          );
        }
      },
    );
  }

  /// 登录并缓存会话；已缓存时直接复用。
  Future<QbSession> ensureSession(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
    bool force = false,
  }) async {
    if (!force) {
      final QbSession? cached = _sessions.get(config.id);
      if (cached != null) return cached;
    }
    final Uri? base = UrlUtils.normalize(config.baseUrl);
    if (base == null) {
      throw const DownloaderFetchException(
        kind: DownloaderFailureKind.unparsed,
        message: '下载器地址不合法，请先修正地址',
      );
    }
    final String username = config.username.trim();
    final String password = credential?['password']?.toString() ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw DownloaderFetchException(
        kind: DownloaderFailureKind.missingCredential,
        message: '${config.name} 缺少 WebUI 用户名或密码：请在下载器里补录账号密码',
        target: base.toString(),
      );
    }

    final Uri target = UrlUtils.joinPath(base, '$_apiPrefix/auth/login');
    try {
      final Response<String> response = await _dio.postUri<String>(
        target,
        data: <String, String>{'username': username, 'password': password},
        cancelToken: cancelToken,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          validateStatus: (int? status) => status != null,
        ),
      );
      final int status = response.statusCode ?? 0;
      final String body = (response.data ?? '').trim();
      if (status == 403) {
        throw DownloaderFetchException(
          kind: DownloaderFailureKind.unauthorized,
          message: '${config.name} 拒绝访问（HTTP 403）：连续登录失败会被临时封禁；'
              '另外 qBittorrent 的 Host header 校验也会拒绝非白名单地址，'
              '请在 WebUI 里把手机访问的地址加入白名单或关闭 Host header 校验',
          target: target.toString(),
          statusCode: status,
        );
      }
      if (body.toLowerCase() != 'ok.') {
        throw DownloaderFetchException(
          kind: DownloaderFailureKind.unauthorized,
          message: '${config.name} 登录失败：请检查 WebUI 用户名与密码（返回「${body.isEmpty ? status : body}」）',
          target: target.toString(),
          statusCode: status,
        );
      }
      final String sid = _sidOf(response.headers);
      final String version = await _fetchVersion(config, sid, cancelToken: cancelToken);
      final QbSession session =
          QbSession(sid: sid, version: version, loggedInAt: DateTime.now());
      _sessions.put(config.id, session);
      return session;
    } on DioException catch (error) {
      throw DownloaderFetchException(
        kind: DownloaderFailureKind.network,
        message: _describeNetwork(config.name, target, error),
        target: target.toString(),
        statusCode: error.response?.statusCode,
      );
    }
  }

  Future<String> _fetchVersion(
    DownloaderConfig config,
    String sid, {
    CancelToken? cancelToken,
  }) async {
    try {
      final Response<String> response = await _dio.getUri<String>(
        UrlUtils.joinPath(UrlUtils.normalize(config.baseUrl)!, '$_apiPrefix/app/version'),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, dynamic>{'Cookie': 'SID=$sid'},
          sendTimeout: timeout,
          receiveTimeout: timeout,
          validateStatus: (int? status) => status != null,
        ),
      );
      return (response.data ?? '').trim();
    } on DioException {
      return '';
    }
  }

  Future<Object?> _getJson(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    String path, {
    CancelToken? cancelToken,
    bool tolerateErrors = false,
  }) async {
    return _withSession<Object?>(
      config,
      credential,
      (QbSession session) async {
        final Response<dynamic> response = await _dio.getUri<dynamic>(
          UrlUtils.joinPath(UrlUtils.normalize(config.baseUrl)!, '$_apiPrefix$path'),
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.json,
            headers: <String, dynamic>{'Cookie': 'SID=${session.sid}'},
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (int? status) => status != null,
          ),
        );
        final int status = response.statusCode ?? 0;
        if (status == 401 || status == 403) {
          throw _SessionExpired(status);
        }
        if (status < 200 || status >= 300) {
          if (tolerateErrors) return null;
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unknown,
            message: '${config.name} 返回 HTTP $status（$path）',
            target: path,
            statusCode: status,
          );
        }
        return response.data;
      },
      tolerateErrors: tolerateErrors,
    );
  }

  Future<List<dynamic>> _getList(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    String path, {
    CancelToken? cancelToken,
  }) async {
    final Object? data = await _getJson(
      config,
      credential,
      path,
      cancelToken: cancelToken,
    );
    if (data is List) return data;
    throw DownloaderFetchException(
      kind: DownloaderFailureKind.unparsed,
      message: '${config.name} 任务列表返回结构不符合预期（期望数组，实际为 '
          '${data == null ? '空' : data.runtimeType}）',
      target: path,
    );
  }

  Future<void> _postForm(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    String path,
    Map<String, String> data,
  ) async {
    await _withSession<void>(
      config,
      credential,
      (QbSession session) async {
        final Response<String> response = await _dio.postUri<String>(
          UrlUtils.joinPath(UrlUtils.normalize(config.baseUrl)!, '$_apiPrefix$path'),
          data: data,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.plain,
            headers: <String, dynamic>{'Cookie': 'SID=${session.sid}'},
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (int? status) => status != null,
          ),
        );
        final int status = response.statusCode ?? 0;
        if (status == 401 || status == 403) {
          throw _SessionExpired(status);
        }
        if (status == 409) {
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unknown,
            message: '${config.name} 拒绝该操作（HTTP 409）：分类/标签可能不存在，'
                '请先在 WebUI 里创建，或换一个已存在的值',
            target: path,
            statusCode: status,
          );
        }
        if (status < 200 || status >= 300) {
          throw DownloaderFetchException(
            kind: DownloaderFailureKind.unknown,
            message: '${config.name} 操作失败（HTTP $status）',
            target: path,
            statusCode: status,
          );
        }
      },
    );
  }

  /// 统一的「带会话执行 + 会话过期重登一次」包装。
  Future<T> _withSession<T>(
    DownloaderConfig config,
    Map<String, dynamic>? credential,
    Future<T> Function(QbSession session) action, {
    bool tolerateErrors = false,
  }) async {
    try {
      final QbSession session = await ensureSession(config, credential: credential);
      try {
        return await action(session);
      } on _SessionExpired {
        final QbSession renewed = await ensureSession(
          config,
          credential: credential,
          force: true,
        );
        return await action(renewed);
      }
    } on DioException catch (error) {
      if (tolerateErrors) return _fallback<T>();
      throw DownloaderFetchException(
        kind: DownloaderFailureKind.network,
        message: _describeNetwork(config.name, Uri.parse(config.baseUrl), error),
        target: config.baseUrl,
        statusCode: error.response?.statusCode,
      );
    }
  }

  T _fallback<T>() {
    if (T == DownloaderTaskOption) return const DownloaderTaskOption() as T;
    if (null is T) return null as T;
    throw StateError('该调用没有可用的降级结果：$T');
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

  static String _sidOf(Headers headers) {
    final List<String>? cookies = headers['set-cookie'];
    for (final String cookie in cookies ?? const <String>[]) {
      final RegExpMatch? match = RegExp(r'SID=([^;]+)').firstMatch(cookie);
      if (match != null) return match.group(1) ?? '';
    }
    return '';
  }

  static String _join(List<String> hashes) =>
      hashes.where((String h) => h.trim().isNotEmpty).join('|');

  static int _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  /// 与 [_int] 的差别：缺失返回 null——「未采集」与真实的 0 必须分得开。
  static int? _intOrNull(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// 把 qBittorrent 的任务字段映射成统一模型。
  static DownloaderTask parseTorrentJson(Map<String, dynamic> json) =>
      _taskFromQb(json);

  static DownloaderTask _taskFromQb(Map<String, dynamic> json) {
    final int size = _int(json['size']);
    final int completed = _int(json['completed']);
    final int eta = _int(json['eta']);
    return DownloaderTask(
      hash: json['hash']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      sizeBytes: size,
      completedBytes: completed,
      state: taskStateOf(json['state']?.toString()),
      downloadSpeed: _int(json['dlspeed']),
      uploadSpeed: _int(json['upspeed']),
      etaSeconds: eta == 8640000 ? 8640000 : (eta <= 0 ? -1 : eta),
      savePath: json['save_path']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      ratio: (json['ratio'] as num?)?.toDouble() ?? 0,
      tags: (json['tags']?.toString() ?? '')
          .split(',')
          .map((String t) => t.trim())
          .where((String t) => t.isNotEmpty)
          .toList(growable: false),
      tracker: json['tracker']?.toString() ?? '',
      magnetUri: json['magnet_uri']?.toString() ?? '',
      forceStart: json['force_start'] == true,
      downloadLimitBytes: _int(json['dl_limit']),
      uploadLimitBytes: _int(json['up_limit']),
      trackersCount: _int(json['trackers_count']),
      addedAt: _addedAt(json['added_on']),
    );
  }

  /// qBittorrent 状态串 → 统一状态（比通用 parser 更准，避免 stalledUP 落到未知）。
  static TaskState taskStateOf(String? raw) {
    final String value = (raw ?? '').toLowerCase();
    if (value.isEmpty) return TaskState.unknown;
    if (value.contains('error') || value.contains('missing')) return TaskState.error;
    if (value.contains('check')) return TaskState.checking;
    if (value.startsWith('paused') ||
        value.startsWith('stopped') ||
        value == 'stoppeddl' ||
        value == 'stoppedup') {
      return TaskState.paused;
    }
    if (value.contains('queued') || value.contains('allocating') || value == 'moving') {
      return TaskState.queued;
    }
    if (value.contains('up') || value.contains('upload') || value.contains('seed')) {
      return TaskState.seeding;
    }
    if (value.contains('dl') || value.contains('download')) return TaskState.downloading;
    return TaskState.unknown;
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
}

/// 内部信号：会话过期（触发一次重新登录）。
class _SessionExpired implements Exception {
  const _SessionExpired(this.statusCode);

  final int statusCode;
}