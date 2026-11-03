import 'package:dio/dio.dart';

import '../config/app_config.dart';

/// 连接测试结果分类。
enum SiteProbeOutcome {
  reachable('可访问'),
  unauthorized('需登录态'),
  unreachable('不可达'),
  invalidUrl('地址无效');

  const SiteProbeOutcome(this.label);

  final String label;

  bool get isSuccess => this == SiteProbeOutcome.reachable || this == SiteProbeOutcome.unauthorized;
}

/// 连接测试结果。
class SiteProbeResult {
  const SiteProbeResult({
    required this.outcome,
    this.statusCode,
    this.message = '',
    this.latencyMs,
  });

  final SiteProbeOutcome outcome;
  final int? statusCode;
  final String message;
  final int? latencyMs;

  bool get isSuccess => outcome.isSuccess;
}

/// 站点直连探测函数（可注入，便于测试）。
typedef SiteProbeFn = Future<SiteProbeResult> Function(Uri baseUrl, Duration timeout);

/// 站点连接测试：只做站点地址的可达性探测，不携带也不解析站点业务数据。
///
/// 站点页面解析、搜索与登录态维护统一由 NAS 后端适配器完成；
/// 本探测用于在录入凭据前后快速确认地址是否写对、线路是否通。
class SiteReachabilityProbe {
  SiteReachabilityProbe({Dio? dio, SiteProbeFn? probe})
      : probe = probe ?? _httpProbe(dio ?? Dio());

  final SiteProbeFn probe;

  Future<SiteProbeResult> call(String baseUrl, {Duration? timeout}) async {
    final Uri? uri = parseSiteUri(baseUrl);
    if (uri == null) {
      return const SiteProbeResult(
        outcome: SiteProbeOutcome.invalidUrl,
        message: '站点地址格式不正确，请填写完整域名',
      );
    }
    return probe(uri, timeout ?? AppConfig.siteProbeTimeout);
  }

  /// 宽松解析站点地址：缺协议时补 `https://`。
  static Uri? parseSiteUri(String raw) {
    final String value = raw.trim();
    if (value.isEmpty) return null;
    final Uri? uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri == null || uri.host.isEmpty) return null;
    return uri;
  }

  static SiteProbeFn _httpProbe(Dio dio) => (Uri baseUrl, Duration timeout) async {
        final Stopwatch watch = Stopwatch()..start();
        try {
          final Response<dynamic> response = await dio.getUri<dynamic>(
            baseUrl,
            options: Options(
              sendTimeout: timeout,
              receiveTimeout: timeout,
              followRedirects: true,
              // 任何 HTTP 响应都说明站点可达，只有网络层失败才算不可达。
              validateStatus: (int? status) => status != null,
            ),
          );
          watch.stop();
          final int status = response.statusCode ?? 0;
          final bool needsLogin = status == 401 || status == 403;
          return SiteProbeResult(
            outcome: needsLogin ? SiteProbeOutcome.unauthorized : SiteProbeOutcome.reachable,
            statusCode: status,
            latencyMs: watch.elapsedMilliseconds,
            message: needsLogin
                ? '站点已连通（HTTP $status），需要有效登录态才能访问'
                : '站点已连通（HTTP $status）',
          );
        } on DioException catch (error) {
          watch.stop();
          return SiteProbeResult(
            outcome: SiteProbeOutcome.unreachable,
            statusCode: error.response?.statusCode,
            latencyMs: watch.elapsedMilliseconds,
            message: switch (error.type) {
              DioExceptionType.connectionTimeout ||
              DioExceptionType.sendTimeout ||
              DioExceptionType.receiveTimeout =>
                '连接超时，请检查地址或当前网络',
              DioExceptionType.badCertificate => '证书校验失败，已拒绝该连接',
              _ => '无法连接该站点，请确认地址正确且网络可达',
            },
          );
        }
      };
}