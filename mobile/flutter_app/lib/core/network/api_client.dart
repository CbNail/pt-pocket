import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'api_exception.dart';
import 'endpoint_resolver.dart';

/// 统一 API 客户端：所有 NAS 后端访问的唯一出口。
///
/// 职责：
/// - 每次请求前通过 [EndpointResolver] 解析可用链路（LAN 优先 / WAN 回退）；
/// - 统一注入会话令牌、幂等键，并做日志脱敏；
/// - 失败时按可重试性做有限退避重试，连接类失败会清理选路缓存并切换链路重试一次。
///
/// 移动端不直连数据库 / Redis，也不在页面内散落站点 HTTP 逻辑（规格书 §7.1）。
class ApiClient {
  ApiClient({required this.resolver, Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = AppConfig.connectTimeout
      ..receiveTimeout = AppConfig.receiveTimeout
      ..headers['Accept'] = 'application/json';
  }

  /// 链路解析器：决定本次请求实际发往内网还是外网。
  final EndpointResolver resolver;

  final Dio _dio;

  /// 供拦截器与诊断日志使用的底层 Dio（不要用于绕过选路逻辑）。
  Dio get raw => _dio;

  void addInterceptor(Interceptor interceptor) => _dio.interceptors.add(interceptor);

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    bool retry = true,
  }) =>
      _send<T>('GET', path, query: query, cancelToken: cancelToken, retry: retry);

  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    bool retry = true,
  }) =>
      _send<T>('POST', path, data: data, query: query, cancelToken: cancelToken, retry: retry);

  Future<Response<T>> put<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    bool retry = true,
  }) =>
      _send<T>('PUT', path, data: data, query: query, cancelToken: cancelToken, retry: retry);

  Future<Response<T>> delete<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    bool retry = true,
  }) =>
      _send<T>('DELETE', path, data: data, query: query, cancelToken: cancelToken, retry: retry);

  /// 直接请求完整 URI（用于已确定链路的探测 / 下载回调）。
  Future<Response<T>> getUri<T>(Uri uri, {CancelToken? cancelToken}) => _dio.getUri<T>(
        uri,
        cancelToken: cancelToken,
        options: Options(receiveTimeout: AppConfig.receiveTimeout),
      );

  Future<Response<T>> _send<T>(
    String method,
    String path, {
    Object? data,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    bool retry = true,
  }) async {
    // 统一使用「基址 + 相对路径」发起请求，基址由选路结果决定。
    final String relative = path.startsWith('/') ? path : '/$path';
    int attempt = 0;
    final int maxAttempts = retry ? AppConfig.maxRetryAttempts : 1;

    while (true) {
      attempt++;
      try {
        final ResolvedEndpoint endpoint = await resolver.resolve(force: attempt > 1);
        _dio.options.baseUrl = endpoint.baseUrl.toString();
        return await _dio.request<T>(
          relative,
          data: data,
          queryParameters: query,
          cancelToken: cancelToken,
          options: Options(method: method),
        );
      } on DioException catch (error) {
        final ApiException mapped = ApiException.fromDio(error);
        if (!_shouldRetry(mapped, attempt, maxAttempts)) {
          throw mapped;
        }
        // 连接类失败：清理选路缓存，下一轮会重新探测（含 LAN→WAN 切换）。
        if (mapped.code == ApiException.netUnreachable || mapped.code == ApiException.netTimeout) {
          resolver.invalidate();
        }
        await Future<void>.delayed(_backoff(attempt));
      } on EndpointUnavailableException {
        rethrow;
      }
    }
  }

  bool _shouldRetry(ApiException error, int attempt, int maxAttempts) {
    if (attempt >= maxAttempts) return false;
    return error.retriable;
  }

  Duration _backoff(int attempt) {
    final int factor = 1 << (attempt - 1); // 1, 2, 4 ...
    return Duration(milliseconds: AppConfig.retryBaseDelay.inMilliseconds * factor);
  }
}