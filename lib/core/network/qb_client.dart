import 'package:dio/dio.dart';
import 'package:pt_pocket/core/network/endpoint.dart';

class QbNotConfigured implements Exception {
  @override
  String toString() => '还未配置 qBittorrent：到「下载器」标签页添加';
}

class QbConfig {
  const QbConfig({
    required this.endpoint,
    required this.username,
    required this.password,
  });
  final DualEndpoint endpoint;
  final String username;
  final String password;
}

/// qBittorrent WebUI 客户端
class QbClient {
  QbClient._(this._dio, this._username, this._password);
  final Dio _dio;
  final String _username;
  final String _password;
  String? _sid;

  factory QbClient.build({
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
    return QbClient._(dio, username, password);
  }

  Map<String, String> get _authHeaders =>
      _sid == null ? const {} : {'Cookie': 'SID=$_sid'};

  Future<void> login() async {
    final r = await _dio.post(
      '/api/v2/auth/login',
      data: 'username=${Uri.encodeQueryComponent(_username)}'
          '&password=${Uri.encodeQueryComponent(_password)}',
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final text = r.data.toString();
    if (!text.contains('Ok')) throw Exception('qB 登录失败：$text（检查账密）');
    final setCookie = r.headers.value('set-cookie') ?? '';
    _sid = RegExp(r'SID=([^;]+)').firstMatch(setCookie)?.group(1);
  }

  Future<String> version() async {
    final r = await _dio.get('/api/v2/app/version',
        options: Options(headers: _authHeaders));
    return r.data.toString();
  }

  /// 添加任务（磁力链/种子 URL），可指定保存目录
  Future<void> addByUrl(String url, {String? savePath}) async {
    var data = 'urls=${Uri.encodeQueryComponent(url)}';
    if (savePath != null && savePath.trim().isNotEmpty) {
      data += '&savepath=${Uri.encodeQueryComponent(savePath.trim())}';
    }
    final r = await _dio.post(
      '/api/v2/torrents/add',
      data: data,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: _authHeaders,
      ),
    );
    if (!r.data.toString().contains('Ok')) {
      throw Exception('qB 添加任务失败：${r.data}');
    }
  }
}
