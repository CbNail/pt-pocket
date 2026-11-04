import '../storage/app_keys.dart';
import '../storage/prefs_store.dart';

/// 一次可达性探测的结果快照。
///
/// 存下来是为了让「重进页面」时能直接显示上次的连通状态，而不是一律显示「未检测」；
/// 只保存结论、状态码、发生时间与当时的请求地址，不含任何凭据。
///
/// 两个结论分开表达，界面才能如实呈现：
/// - [reachable]：地址连上了（拿到了 HTTP 响应）；
/// - [usable]：该地址真能干活（健康响应 2xx + JSON，或站点侧可访问）；
///   「地址通、但后端还没部署」属于 reachable 为真而 usable 为假。
class ProbeSnapshot {
  const ProbeSnapshot({
    required this.reachable,
    required this.usable,
    this.statusCode,
    this.message = '',
    this.url = '',
    this.probedAt,
  });

  final bool reachable;
  final bool usable;
  final int? statusCode;
  final String message;
  final String url;
  final DateTime? probedAt;

  bool get hasResult => probedAt != null;

  /// 未连通（网络层失败）。
  bool get failed => !reachable;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'reachable': reachable,
        'usable': usable,
        'statusCode': statusCode,
        'message': message,
        'url': url,
        'probedAt': probedAt?.toIso8601String(),
      };

  factory ProbeSnapshot.fromJson(Map<String, dynamic> json) => ProbeSnapshot(
        // 兼容早期只写 ok 的数据。
        reachable: json['reachable'] as bool? ?? json['ok'] as bool? ?? false,
        usable: json['usable'] as bool? ?? json['ok'] as bool? ?? false,
        statusCode: (json['statusCode'] as num?)?.toInt(),
        message: json['message']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        probedAt: json['probedAt'] is String
            ? DateTime.tryParse(json['probedAt'] as String)
            : null,
      );
}

/// 探测结果存储：按目标 key 保存最近一次结果。
///
/// key 约定：
/// - `endpoint.lan` / `endpoint.wan`：连接与服务的两条通道；
/// - `downloader.<id>`：下载器地址；
/// - `mp.<id>.lan` / `mp.<id>.wan`：MoviePilot 的两条通道；
/// - `cookiecloud`：CookieCloud 服务地址。
class ProbeResultStore {
  ProbeResultStore({required this.prefs});

  final PrefsStore prefs;

  ProbeSnapshot? read(String key) {
    final Map<String, dynamic>? json = prefs.getJson(PrefKeys.probePrefix + key);
    if (json == null) return null;
    return ProbeSnapshot.fromJson(json);
  }

  Future<void> write(String key, ProbeSnapshot snapshot) =>
      prefs.setJson(PrefKeys.probePrefix + key, snapshot.toJson());

  Future<void> clear(String key) => prefs.remove(PrefKeys.probePrefix + key);

  /// 清空以某前缀开头的探测结果（例如站点被删除后清理 `site.<id>`）。
  Future<void> clearPrefixed(String prefix) async {
    final String full = PrefKeys.probePrefix + prefix;
    for (final String key in prefs.namespacedKeys()) {
      if (key.startsWith(full)) {
        await prefs.remove(key);
      }
    }
  }
}