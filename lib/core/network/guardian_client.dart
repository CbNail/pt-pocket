import 'package:dio/dio.dart';

class GuardianConfig {
  const GuardianConfig({required this.url, required this.token});
  final String url;
  final String token;
}

class GuardianNotConfigured implements Exception {}

class GuardianSite {
  const GuardianSite({
    required this.name,
    required this.url,
    required this.ok,
    required this.fails,
    required this.latencyMs,
    required this.alerted,
  });

  factory GuardianSite.fromJson(String name, Map<String, dynamic> j) =>
      GuardianSite(
        name: name,
        url: j['url'] as String? ?? '',
        ok: j['ok'] as bool?,
        fails: (j['fails'] as num?)?.toInt() ?? 0,
        latencyMs: (j['latency_ms'] as num?)?.toInt(),
        alerted: j['alerted'] as bool? ?? false,
      );

  final String name;
  final String url;
  final bool? ok;
  final int fails;
  final int? latencyMs;
  final bool alerted;
}

class GuardianClient {
  GuardianClient._(this._dio);
  final Dio _dio;

  factory GuardianClient.build(GuardianConfig cfg) {
    var base = cfg.url.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final dio = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.headers['Authorization'] = 'Bearer ${cfg.token}';
        handler.next(options);
      },
    ));
    return GuardianClient._(dio);
  }

  /// 探活：服务是否在线（无需鉴权）
  Future<void> pingHealth() async {
    await _dio.get('/health');
  }

  /// 拉取监测状态（需令牌）
  Future<List<GuardianSite>> fetchStatus() async {
    final r = await _dio.get('/api/v1/status');
    final sites = (r.data as Map<String, dynamic>)['sites'] as Map<String, dynamic>;
    return sites.entries
        .map((e) => GuardianSite.fromJson(
            e.key, (e.value as Map).cast<String, dynamic>()))
        .toList();
  }
}
