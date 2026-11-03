import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// 注入 NAS 会话令牌；不携带站点凭据与下载器账号（那些由 NAS 侧持有）。
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.tokenReader, this.onUnauthorized});

  final Future<String?> Function() tokenReader;
  final Future<void> Function()? onUnauthorized;

  static const String headerName = 'X-Session-Token';

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    final String? token = await tokenReader();
    if (token != null && token.isNotEmpty) {
      options.headers[headerName] = token;
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 401) {
      await onUnauthorized?.call();
    }
    handler.next(err);
  }
}

/// 写操作幂等键：链路切换 / 重试时避免重复创建任务（规格书 §7.5）。
class IdempotencyInterceptor extends Interceptor {
  IdempotencyInterceptor({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  static const String headerName = 'X-Idempotency-Key';
  static const Set<String> _writeMethods = <String>{'POST', 'PUT', 'PATCH', 'DELETE'};

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_writeMethods.contains(options.method.toUpperCase()) &&
        !options.headers.containsKey(headerName)) {
      options.headers[headerName] = _uuid.v4();
    }
    handler.next(options);
  }
}

/// 日志脱敏拦截器：只记录方法 / 路径 / 状态 / 耗时，屏蔽凭据类字段。
class RedactingLogInterceptor extends Interceptor {
  RedactingLogInterceptor({this.enabled = kDebugMode});

  final bool enabled;

  static const Set<String> _sensitiveHeaders = <String>{
    'authorization',
    'cookie',
    'set-cookie',
    'x-session-token',
    'x-api-key',
    'x-idempotency-key',
  };

  static const String _tag = '[ApiClient]';

  DateTime? _start;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _start = DateTime.now();
    if (enabled) {
      debugPrint('$_tag → ${options.method} ${_safePath(options)}');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    if (enabled) {
      final int ms = DateTime.now().difference(_start ?? DateTime.now()).inMilliseconds;
      debugPrint(
          '$_tag ← ${response.statusCode} ${_safePath(response.requestOptions)} ${ms}ms');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (enabled) {
      final int ms = DateTime.now().difference(_start ?? DateTime.now()).inMilliseconds;
      debugPrint(
          '$_tag ✗ ${err.type.name} ${_safePath(err.requestOptions)} ${ms}ms');
    }
    handler.next(err);
  }

  /// 去掉 query 中的敏感参数，只保留路径。
  static String _safePath(RequestOptions options) {
    final Uri uri = options.uri;
    final Map<String, String> redacted = <String, String>{};
    uri.queryParameters.forEach((String key, String value) {
      redacted[key] = _isSensitive(key) ? '***' : value;
    });
    return uri.replace(queryParameters: redacted).toString();
  }

  static bool _isSensitive(String key) {
    final String k = key.toLowerCase();
    return k.contains('token') ||
        k.contains('pass') ||
        k.contains('key') ||
        k.contains('secret') ||
        k.contains('cookie');
  }

  /// 供外部（如诊断日志导出）复用的头部脱敏。
  static Map<String, dynamic> redactHeaders(Map<String, dynamic> headers) {
    final Map<String, dynamic> out = <String, dynamic>{};
    headers.forEach((String key, dynamic value) {
      out[key] = _sensitiveHeaders.contains(key.toLowerCase()) ? '***' : value;
    });
    return out;
  }
}