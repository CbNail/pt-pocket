/// 下载器与下载任务模型（跨引擎归一化）。
///
/// 引擎差异（qBittorrent WebUI / Transmission RPC / Aria2 JSON-RPC）由服务端
/// 适配器消解；移动端只需要一套统一的字段与状态语义。
library;

/// 下载器类型。
enum DownloaderKind {
  qbittorrent('qBittorrent', 'WebUI API（/api/v2）'),
  transmission('Transmission', 'RPC 接口（/transmission/rpc）'),
  aria2('Aria2', 'JSON-RPC 接口');

  const DownloaderKind(this.label, this.description);

  final String label;
  final String description;

  static DownloaderKind fromName(String? value) => values.firstWhere(
        (DownloaderKind k) => k.name == value,
        orElse: () => DownloaderKind.qbittorrent,
      );
}

/// 下载器连接状态。
enum DownloaderHealth {
  unknown('未测试'),
  ok('正常'),
  warning('需关注'),
  danger('异常');

  const DownloaderHealth(this.label);

  final String label;

  static DownloaderHealth fromName(String? value) => values.firstWhere(
        (DownloaderHealth h) => h.name == value,
        orElse: () => DownloaderHealth.unknown,
      );
}

/// 下载器配置（非机密；用户名在配置里，密码在安全存储）。
class DownloaderConfig {
  const DownloaderConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.username = '',
    this.credentialConfigured = false,
    this.enabled = true,
    this.defaultSavePath = '',
    this.health = DownloaderHealth.unknown,
    this.lastTestedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final DownloaderKind kind;
  final String baseUrl;
  final String username;
  final bool credentialConfigured;
  final bool enabled;

  /// 该下载器的默认保存目录（推送到该下载器时的默认值）。
  final String defaultSavePath;
  final DownloaderHealth health;
  final DateTime? lastTestedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get host => Uri.tryParse(baseUrl)?.host ?? baseUrl;

  DownloaderConfig copyWith({
    String? id,
    String? name,
    DownloaderKind? kind,
    String? baseUrl,
    String? username,
    bool? credentialConfigured,
    bool? enabled,
    String? defaultSavePath,
    DownloaderHealth? health,
    DateTime? lastTestedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      DownloaderConfig(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        credentialConfigured: credentialConfigured ?? this.credentialConfigured,
        enabled: enabled ?? this.enabled,
        defaultSavePath: defaultSavePath ?? this.defaultSavePath,
        health: health ?? this.health,
        lastTestedAt: lastTestedAt ?? this.lastTestedAt,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.name,
        'baseUrl': baseUrl,
        'username': username,
        'credentialConfigured': credentialConfigured,
        'enabled': enabled,
        'defaultSavePath': defaultSavePath,
        'health': health.name,
        'lastTestedAt': lastTestedAt?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  factory DownloaderConfig.fromJson(Map<String, dynamic> json) => DownloaderConfig(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        kind: DownloaderKind.fromName(json['kind'] as String?),
        baseUrl: json['baseUrl'] as String? ?? '',
        username: json['username'] as String? ?? '',
        credentialConfigured: json['credentialConfigured'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
        defaultSavePath: json['defaultSavePath'] as String? ?? '',
        health: DownloaderHealth.fromName(json['health'] as String?),
        lastTestedAt: _parseDate(json['lastTestedAt']),
        createdAt: _parseDate(json['createdAt']),
        updatedAt: _parseDate(json['updatedAt']),
      );
}

/// 归一化后的任务状态。
enum TaskState {
  downloading('下载中'),
  seeding('做种中'),
  paused('已暂停'),
  queued('排队中'),
  checking('校验中'),
  completed('已完成'),
  error('错误'),
  unknown('未知');

  const TaskState(this.label);

  final String label;

  /// 把各引擎的原始状态字符串归一化。
  static TaskState parse(String? raw) {
    final String value = (raw ?? '').toLowerCase();
    if (value.isEmpty) return TaskState.unknown;
    if (value.contains('error') || value.contains('missing')) return TaskState.error;
    if (value.contains('check')) return TaskState.checking;
    if (value.contains('pause') || value == 'stopped' || value == 'stop') return TaskState.paused;
    if (value.contains('queue') || value.contains('wait')) return TaskState.queued;
    if (value.contains('seed') || value.contains('upload')) return TaskState.seeding;
    if (value.contains('download') || value == 'dl' || value == 'active') return TaskState.downloading;
    if (value.contains('complete') || value.contains('finish') || value.contains('done')) {
      return TaskState.completed;
    }
    return TaskState.unknown;
  }

  bool get isPaused => this == TaskState.paused;

  bool get isActive => this == TaskState.downloading || this == TaskState.seeding;
}

/// 下载任务（跨引擎归一化视图）。
class DownloaderTask {
  const DownloaderTask({
    required this.hash,
    required this.name,
    this.sizeBytes = 0,
    this.completedBytes = 0,
    this.state = TaskState.unknown,
    this.downloadSpeed = 0,
    this.uploadSpeed = 0,
    this.etaSeconds = -1,
    this.savePath = '',
    this.category = '',
    this.ratio = 0,
  });

  /// 任务唯一标识（qBittorrent / Transmission 均为 info hash）。
  final String hash;
  final String name;
  final int sizeBytes;
  final int completedBytes;
  final TaskState state;
  final int downloadSpeed;
  final int uploadSpeed;

  /// 剩余秒数；负数表示未知，8640000 及以上表示不限。
  final int etaSeconds;
  final String savePath;
  final String category;
  final double ratio;

  double get progress => sizeBytes <= 0 ? 0 : (completedBytes / sizeBytes).clamp(0, 1);

  /// 解析服务端（已归一化）或引擎原生字段。
  factory DownloaderTask.fromJson(Map<String, dynamic> json) {
    final int size = _num(json, <String>['sizeBytes', 'size', 'totalSize', 'totalLength']).toInt();
    int completed =
        _num(json, <String>['completedBytes', 'completed', 'completedLength']).toInt();
    if (completed <= 0) {
      // Transmission 只给 percentDone（0–1），qBittorrent 给 progress（0–1）。
      final double percent = _num(json, <String>['percentDone', 'progress']).toDouble();
      if (percent > 0 && size > 0) {
        completed = (size * (percent > 1 ? percent / 100 : percent)).round();
      }
    }
    final int eta = _num(json, <String>['etaSeconds', 'eta']).toInt();

    return DownloaderTask(
      hash: _str(json, <String>['hash', 'hashString', 'gid', 'id']),
      name: _str(json, <String>['name', 'title', 'fileName']),
      sizeBytes: size,
      completedBytes: completed,
      state: TaskState.parse(_str(json, <String>['state', 'status', 'downloadState'])),
      downloadSpeed: _num(json, <String>['downloadSpeed', 'dlspeed', 'rateDownload']).toInt(),
      uploadSpeed: _num(json, <String>['uploadSpeed', 'upspeed', 'rateUpload']).toInt(),
      etaSeconds: eta == 0 ? -1 : eta,
      savePath: _str(json, <String>['savePath', 'save_path', 'downloadDir', 'dir']),
      category: _str(json, <String>['category', 'labels', 'tag']),
      ratio: _num(json, <String>['ratio', 'uploadRatio']).toDouble(),
    );
  }

  static num _num(Map<String, dynamic> json, List<String> keys) {
    for (final String key in keys) {
      final Object? value = json[key];
      if (value is num) return value;
      if (value is String) {
        final num? parsed = num.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  static String _str(Map<String, dynamic> json, List<String> keys) {
    for (final String key in keys) {
      final Object? value = json[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is List && value.isNotEmpty) return value.first.toString();
    }
    return '';
  }
}

DateTime? _parseDate(Object? value) => value is String ? DateTime.tryParse(value) : null;