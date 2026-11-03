import 'package:dio/dio.dart';

/// 统一 API 异常：把 Dio / 网络 / 服务端错误映射为可展示的领域错误。
///
/// 错误码对齐规格书 §9.5：服务端返回 {code, message}；网络层错误使用本地前缀
/// `NET_*`，避免与业务错误码混用。
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.cause,
    this.retriable = false,
  });

  /// 业务错误码（服务端）或网络错误码（NET_*，本地）。
  final String code;

  /// 面向用户的可读信息。
  final String message;

  /// HTTP 状态码（若有）。
  final int? statusCode;

  /// 原始错误，仅用于诊断日志，不直接展示给用户。
  final Object? cause;

  /// 是否可通过重试恢复（超时、连接失效、5xx 等）。
  final bool retriable;

  static const String netUnreachable = 'NET_UNREACHABLE';
  static const String netTimeout = 'NET_TIMEOUT';
  static const String netCanceled = 'NET_CANCELED';
  static const String netTls = 'NET_TLS';
  static const String netUnknown = 'NET_UNKNOWN';
  static const String unauthorized = 'AUTH_401';
  static const String forbidden = 'AUTH_403';
  static const String rateLimited = 'RATE_LIMITED';

  factory ApiException.fromDio(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException(
          code: netTimeout,
          message: '连接超时，请检查链路或稍后重试',
          cause: error,
          retriable: true,
        );
      case DioExceptionType.badCertificate:
        return ApiException(code: netTls, message: '证书校验失败，已拒绝不安全连接', cause: error);
      case DioExceptionType.cancel:
        return ApiException(code: netCanceled, message: '请求已取消', cause: error);
      case DioExceptionType.connectionError:
        return ApiException(
          code: netUnreachable,
          message: '无法连接服务，请确认内网或外网链路',
          cause: error,
          retriable: true,
        );
      case DioExceptionType.badResponse:
        final int? status = error.response?.statusCode;
        if (status == 401) {
          return ApiException(code: unauthorized, message: '登录状态已失效，请重新配对', statusCode: status, cause: error);
        }
        if (status == 403) {
          return ApiException(code: forbidden, message: '没有权限执行该操作', statusCode: status, cause: error);
        }
        if (status == 429) {
          return ApiException(code: rateLimited, message: '请求过于频繁，请稍后重试', statusCode: status, cause: error, retriable: true);
        }
        final Object? data = error.response?.data;
        String code = 'HTTP_${status ?? 0}';
        String message = '服务端返回错误';
        if (data is Map) {
          final Object? serverCode = data['code'];
          final Object? serverMessage = data['message'] ?? data['detail'];
          if (serverCode is String && serverCode.isNotEmpty) code = serverCode;
          if (serverMessage is String && serverMessage.isNotEmpty) message = serverMessage;
        }
        return ApiException(
          code: code,
          message: message,
          statusCode: status,
          cause: error,
          retriable: status != null && status >= 500,
        );
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        return ApiException(code: netUnknown, message: '网络请求失败', cause: error, retriable: true);
    }
  }

  @override
  String toString() => 'ApiException($code${statusCode != null ? ' · $statusCode' : ''}): $message';
}