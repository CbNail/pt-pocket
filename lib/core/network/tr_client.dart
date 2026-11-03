import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:pt_pocket/core/network/endpoint.dart';

class TrNotConfigured implements Exception {
  @override
  String toString() => '还未配置 Transmission：到「下载器」标签页添加';
}

class TrConfig {
  const TrConfig({
    required this.endpoint,
    required this.username,
    required this.password,
  });
  final DualEndpoint endpoint;
  final String username;
  final String password;
}

/// Transmission RPC 客户端（首次请求 409 换取 session id 后重试）
class TrClient {
  TrClient._(this._dio, this._username, this._password);
  final Dio _dio;
  final String _username;
  final String _password;
  String? _sessionId;

  factory TrClient.build({
    required String baseUrl,
    required String username,
    required String password,
  }) {
    var base = baseUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final dio = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ));
    return TrClient._(dio, username, password);
  }

  Map<String, String> get _headers {
    final h = <String, String>{'Content-Type': 'application/json; charset=utf-8'};
    if (_username.isNotEmpty) {
      h['Authorization'] =
          'Basic ${base64Encode(utf8.encode('$_username:$_password'))}';
    }
    if (_sessionId != null) h['X-Transmission-Session-Id'] = _sessionId!;
    return h;
  }

  Future<Map<String, dynamic>> rpc(
      String method, Map<String, dynamic> args) async {
    Future<Map<String, dynamic>> call() async {
      final r = await _dio.post('/transmission/rpc',
          data: {'method': method, 'arguments': args},
          options: Options(headers: _headers));
      return (r.data as Map).cast<String, dynamic>();
    }

    try {
      return await call();
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        _sessionId = e.response?.headers.value('x-transmission-session-id');
        return await call();
      }
      rethrow;
    }
  }

  Future<String> version() async {
    final resp = await rpc('session-get', {});
    final args =
        (resp['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
    return args['version']?.toString() ?? '?';
  }

  Future<void> addTorrent(String urlOrMagnet, {String? downloadDir}) async {
    final args = <String, dynamic>{'filename': urlOrMagnet};
    if (downloadDir != null && downloadDir.trim().isNotEmpty) {
      args['download-dir'] = downloadDir.trim();
    }
    final resp = await rpc('torrent-add', args);
    final result = resp['result']?.toString() ?? '';
    if (result != 'success') throw Exception('TR 添加失败：$result');
  }
}
