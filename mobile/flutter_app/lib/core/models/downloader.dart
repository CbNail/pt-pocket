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
    this.isDefault = false,
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

  /// 是否为默认下载器：搜索结果不指定目标时推送到该下载器。
  /// 同一时刻只允许一个默认下载器（由仓库统一收敛）。
  final bool isDefault;

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
    bool? isDefault,
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
        isDefault: isDefault ?? this.isDefault,
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
        'isDefault': isDefault,
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
        isDefault: json['isDefault'] as bool? ?? false,
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
    this.tags = const <String>[],
    this.tracker = '',
    this.addedAt,
    this.magnetUri = '',
    this.forceStart = false,
    this.downloadLimitBytes = 0,
    this.uploadLimitBytes = 0,
    this.trackersCount = 0,
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

  /// 标签（qBittorrent 的 tags / Transmission 的 labels）。
  final List<String> tags;

  /// 当前 tracker 或站点域名，用于「服务器筛选」。
  final String tracker;

  /// 加入时间；服务端未提供时为 null（排序时统一落到末尾）。
  final DateTime? addedAt;

  /// 磁力链接（qBittorrent 的 `magnet_uri` / Transmission 的 `magnetLink`）；空表示引擎未提供。
  /// 只用于「复制磁力链接」这类本机操作，不参与筛选与排序。
  final String magnetUri;

  /// 是否强制开始（qBittorrent 的 `force_start`；Transmission 的强制开始由「立即开始」下发）。
  final bool forceStart;

  /// 单任务下载 / 上传限速（字节/秒）；0 表示不限。
  final int downloadLimitBytes;
  final int uploadLimitBytes;

  /// tracker 数量；0 表示引擎未提供（qBittorrent 的 `trackers_count`）。
  final int trackersCount;

  bool get isPaused => state.isPaused;

  /// 服务器（tracker / 站点）展示名：取 tracker 主机名，空则显示未标注。
  String get serverLabel {
    if (tracker.isEmpty) return '未标注';
    final Uri? uri = Uri.tryParse(tracker.contains('://') ? tracker : 'http://$tracker');
    final String host = uri?.host ?? tracker;
    return host.isEmpty ? tracker : host;
  }

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
      // Transmission 没有独立分类，其 labels 同时充当分类与标签，两个字段都填。
      category: _str(json, <String>['category', 'labels', 'tag']),
      ratio: _num(json, <String>['ratio', 'uploadRatio']).toDouble(),
      tags: _strList(json, <String>['tags', 'labels']),
      tracker: _str(json, <String>['tracker', 'trackerHost', 'siteName', 'site']),
      magnetUri: _str(json, <String>['magnetUri', 'magnet_uri', 'magnetLink']),
      forceStart: json['forceStart'] == true || json['force_start'] == true,
      downloadLimitBytes:
          _num(json, <String>['downloadLimitBytes', 'dl_limit', 'downloadLimit']).toInt(),
      uploadLimitBytes: _num(json, <String>['uploadLimitBytes', 'up_limit', 'uploadLimit']).toInt(),
      trackersCount: _num(json, <String>['trackersCount', 'trackers_count']).toInt(),
      addedAt: _parseDate(
        json['addedAt'] ?? json['addedOn'] ?? json['addedTime'] ?? json['added_time'] ??
            json['additionDate'] ?? json['dateAdded'],
      ),
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

  /// 多值字段（标签可能以数组、逗号串或单个字符串给出）。
  static List<String> _strList(Map<String, dynamic> json, List<String> keys) {
    for (final String key in keys) {
      final Object? value = json[key];
      if (value is List) {
        return value
            .map((Object? item) => item.toString().trim())
            .where((String item) => item.isNotEmpty)
            .toList(growable: false);
      }
      if (value is String && value.trim().isNotEmpty) {
        return value
            .split(',')
            .map((String item) => item.trim())
            .where((String item) => item.isNotEmpty)
            .toList(growable: false);
      }
    }
    return const <String>[];
  }
}

/// 任务排序字段。
enum TaskSort {
  addedAt('加入时间'),
  name('名称'),
  size('大小'),
  progress('进度'),
  downloadSpeed('下载速度'),
  eta('剩余时间');

  const TaskSort(this.label);

  final String label;

  static TaskSort fromName(String? value) => values.firstWhere(
        (TaskSort s) => s.name == value,
        orElse: () => TaskSort.addedAt,
      );
}

/// 任务列表的筛选 / 排序条件（纯数据，便于单测）。
class TaskQuery {
  const TaskQuery({
    this.statuses = const <TaskState>{},
    this.categories = const <String>{},
    this.tags = const <String>{},
    this.paths = const <String>{},
    this.servers = const <String>{},
    this.sort = TaskSort.addedAt,
    this.descending = true,
  });

  /// 选中的状态集合；空集表示「全部状态」。
  final Set<TaskState> statuses;

  /// 选中的分类；空集表示「全部分类」。按精确匹配过滤。
  final Set<String> categories;

  /// 选中的标签；空集表示「全部标签」。任务带其中任意一个即命中。
  final Set<String> tags;

  /// 选中的保存路径；空集表示「全部路径」。按精确匹配过滤。
  final Set<String> paths;

  /// 选中的服务器（tracker / 站点域名）；空集表示「全部服务器」。
  final Set<String> servers;

  final TaskSort sort;

  /// 是否倒序（默认：新加入在前）。
  final bool descending;

  bool get isEmptyFilter =>
      statuses.isEmpty && categories.isEmpty && tags.isEmpty && paths.isEmpty && servers.isEmpty;

  /// 生效中的筛选维度数量（界面用来提示「筛选中」）。
  int get activeFilterCount =>
      (statuses.isEmpty ? 0 : 1) +
      (categories.isEmpty ? 0 : 1) +
      (tags.isEmpty ? 0 : 1) +
      (paths.isEmpty ? 0 : 1) +
      (servers.isEmpty ? 0 : 1);

  TaskQuery copyWith({
    Set<TaskState>? statuses,
    Set<String>? categories,
    Set<String>? tags,
    Set<String>? paths,
    Set<String>? servers,
    TaskSort? sort,
    bool? descending,
  }) =>
      TaskQuery(
        statuses: statuses ?? this.statuses,
        categories: categories ?? this.categories,
        tags: tags ?? this.tags,
        paths: paths ?? this.paths,
        servers: servers ?? this.servers,
        sort: sort ?? this.sort,
        descending: descending ?? this.descending,
      );

  /// 过滤 + 排序。纯函数，供页面与单测共用同一口径。
  List<DownloaderTask> apply(List<DownloaderTask> tasks) {
    final List<DownloaderTask> filtered = tasks
        .where((DownloaderTask task) =>
            (statuses.isEmpty || statuses.contains(task.state)) &&
            (categories.isEmpty || categories.contains(task.category)) &&
            (paths.isEmpty || paths.contains(task.savePath)) &&
            (servers.isEmpty || servers.contains(task.tracker)) &&
            (tags.isEmpty || task.tags.any(tags.contains)))
        .toList();

    int compare(DownloaderTask a, DownloaderTask b) {
      final int result = switch (sort) {
        TaskSort.addedAt => (a.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(b.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
        TaskSort.name => a.name.compareTo(b.name),
        TaskSort.size => a.sizeBytes.compareTo(b.sizeBytes),
        TaskSort.progress => a.progress.compareTo(b.progress),
        TaskSort.downloadSpeed => a.downloadSpeed.compareTo(b.downloadSpeed),
        TaskSort.eta => a.etaSeconds.compareTo(b.etaSeconds),
      };
      // 排序键相同时用名称兜底，保证结果稳定（否则同键项顺序随机跳变）。
      return result != 0 ? result : a.name.compareTo(b.name);
    }

    filtered.sort((DownloaderTask a, DownloaderTask b) =>
        descending ? compare(b, a) : compare(a, b));
    return filtered;
  }
}

/// 添加任务的请求（界面收集 → 网关下发）。
class AddTaskRequest {
  const AddTaskRequest({
    this.links = const <String>[],
    this.fileName = '',
    this.fileBytes = const <int>[],
    this.autoManaged = false,
    this.category = '',
    this.tags = const <String>[],
    this.savePath = '',
    this.paused = false,
  });

  /// 种子链接 / 磁力链接（已按行拆分、去掉空行）。
  final List<String> links;

  /// 种子文件名与字节流（未选择文件时为空）。
  final String fileName;
  final List<int> fileBytes;

  /// 是否交由下载器自动管理（Transmission 的 `auto-managed`；qBittorrent 无此开关）。
  final bool autoManaged;

  final String category;
  final List<String> tags;
  final String savePath;

  /// 添加后是否暂停。
  final bool paused;

  bool get hasFile => fileName.isNotEmpty && fileBytes.isNotEmpty;

  /// 本次要提交的任务数（1 个种子文件算 1 条）。
  int get itemCount => links.length + (hasFile ? 1 : 0);

  bool get isEmpty => itemCount == 0;
}

/// 下载器可选值（分类 / 标签 / 路径），供任务批量操作的选择器使用。
///
/// 由后端一次下发，避免在页面上拼三次请求；字段缺失时按空列表处理。
class DownloaderTaskOption {
  const DownloaderTaskOption({
    this.categories = const <String>[],
    this.tags = const <String>[],
    this.paths = const <String>[],
  });

  final List<String> categories;
  final List<String> tags;
  final List<String> paths;

  factory DownloaderTaskOption.fromJson(Map<String, dynamic> json) => DownloaderTaskOption(
        categories: _stringList(json['categories']),
        tags: _stringList(json['tags']),
        paths: _stringList(json['paths']),
      );

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .map((Object? item) => item.toString().trim())
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
  }
}

/// 单个下载器的聚合统计（列表卡片与网格图表共用同一份口径）。
///
/// 「已采集」与「未采集」分得很清：任务列表取到了就是 [sampled] = true；
/// 引擎没提供的字段（剩余空间、限速、版本）保持 null 或空串，界面显示「未采集」，
/// 不用 0 冒充。
class DownloaderStats {
  const DownloaderStats({
    this.total = 0,
    this.stateCounts = const <TaskState, int>{},
    this.categoryCounts = const <String, int>{},
    this.downloadSpeed = 0,
    this.uploadSpeed = 0,
    this.freeSpaceBytes,
    this.downloadLimitBytes,
    this.uploadLimitBytes,
    this.version = '',
    this.sampled = false,
    this.failureMessage = '',
  });

  /// 种子总数。
  final int total;

  /// 各状态的任务数（未出现的状态按 0 处理）。
  final Map<TaskState, int> stateCounts;

  /// 分类 → 任务数（图表用）；没有分类的任务归到「未分类」。
  final Map<String, int> categoryCounts;

  final int downloadSpeed;
  final int uploadSpeed;

  /// 剩余磁盘空间（字节）；null 表示引擎未提供。
  final int? freeSpaceBytes;

  /// 全局下载 / 上传限速（字节/秒）；0 表示不限，null 表示未采集。
  final int? downloadLimitBytes;
  final int? uploadLimitBytes;

  /// 引擎版本；空串表示未采集。
  final String version;

  /// 任务列表是否真的取到了（false 时整张卡片按「未采集」呈现）。
  final bool sampled;

  /// 采集失败的原因（界面直接显示原因，而不是把失败画成 0）。
  final String failureMessage;

  int countOf(TaskState state) => stateCounts[state] ?? 0;

  /// 按任务列表统计；引擎级字段（速率 / 限速 / 剩余空间 / 版本）由调用方传入。
  factory DownloaderStats.fromTasks(
    List<DownloaderTask> tasks, {
    int? downloadSpeed,
    int? uploadSpeed,
    int? freeSpaceBytes,
    int? downloadLimitBytes,
    int? uploadLimitBytes,
    String version = '',
  }) {
    final Map<TaskState, int> counts = <TaskState, int>{};
    final Map<String, int> categories = <String, int>{};
    for (final DownloaderTask task in tasks) {
      counts[task.state] = (counts[task.state] ?? 0) + 1;
      final String key = task.category.trim().isEmpty ? '未分类' : task.category.trim();
      categories[key] = (categories[key] ?? 0) + 1;
    }
    return DownloaderStats(
      total: tasks.length,
      stateCounts: counts,
      categoryCounts: categories,
      downloadSpeed: downloadSpeed ?? 0,
      uploadSpeed: uploadSpeed ?? 0,
      freeSpaceBytes: freeSpaceBytes,
      downloadLimitBytes: downloadLimitBytes,
      uploadLimitBytes: uploadLimitBytes,
      version: version,
      sampled: true,
    );
  }
}

/// 宽松解析时间：兼容 ISO 字符串与各引擎给出的 epoch（秒或毫秒）数字。
///
/// qBittorrent 的 `added_on` / Transmission 的 `addedDate` 都是 epoch 秒，
/// 只按 ISO 字符串解析会把「加入时间」整列丢掉，排序随之失真。
DateTime? _parseDate(Object? value) {
  if (value is num) {
    final int raw = value.toInt();
    if (raw <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(raw > 100000000000 ? raw : raw * 1000);
  }
  if (value is String) {
    final String text = value.trim();
    if (text.isEmpty) return null;
    final int? epoch = int.tryParse(text);
    if (epoch != null) return _parseDate(epoch);
    return DateTime.tryParse(text);
  }
  return null;
}