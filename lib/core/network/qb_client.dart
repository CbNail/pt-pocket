import 'package:dio/dio.dart';

class QbNotConfigured implements Exception {
  @override
  String toString() => '还未配置 qBittorrent：到「设置」页「服务连接 · qBittorrent」填写';
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

/// qBittorrent WebUI 客户端（会话 SID 手动管理，不引入额外依赖）
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
      receiveTimeout: const Duration(seconds: 15),
    ));
    return QbClient._(dio, username, password);
  }

  Map<String, String> get _authHeaders =>
      _sid == null ? const {} : {'Cookie': 'SID=$_sid'};

  /// 登录并保存会话 SID
  Future<void> login() async {
    final r = await _dio.post(
      '/api/v2/auth/login',
      data: 'username=${Uri.encodeQueryComponent(_username)}'
          '&password=${Uri.encodeQueryComponent(_password)}',
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final text = r.data.toString();
    if (!text.contains('Ok')) {
      throw Exception('qB 登录失败：$text（检查用户名密码）');
    }
    final setCookie = r.headers.value('set-cookie') ?? '';
    _sid = RegExp(r'SID=([^;]+)').firstMatch(setCookie)?.group(1);
  }

  /// qB 版本号（测试连接用）
  Future<String> version() async {
    final r = await _dio.get('/api/v2/app/version',
        options: Options(headers: _authHeaders));
    return r.data.toString();
  }

  /// 添加下载任务（磁力链或 .torrent URL）
  Future<void> addByUrl(String url) async {
    final r = await _dio.post(
      '/api/v2/torrents/add',
      data: 'urls=${Uri.encodeQueryComponent(url)}',
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: _authHeaders,
      ),
    );
    final text = r.data.toString();
    if (!text.contains('Ok')) {
      throw Exception('qB 添加任务失败：$text');
    }
  }
}
