import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/proxy_settings.dart';

/// 把 App 代理设置套用到 Dio。
///
/// 依据 dart:io 的实现（`_ProxyConfiguration` 只解析 `PROXY host:port` 与
/// `DIRECT`），这里只支持 HTTP 代理；认证通过 `HttpClient.addProxyCredentials`
/// 注入，不把口令拼进代理指令（避免口令含 `:` 或 `@` 时解析歧义）。
///
/// 内网/本机地址（NAS 内网地址等）始终直连，外网请求才走代理。
class ProxyManager {
  const ProxyManager._();

  static void apply(Dio dio, ProxySettings settings, {String? password}) {
    // 直接替换适配器实例：旧适配器会缓存已建立的 HttpClient，
    // 替换实例可确保修改代理设置后立即生效。
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => buildClient(settings, password: password),
    );
  }

  /// 构造带代理配置的 HttpClient（单独暴露便于测试与诊断）。
  static HttpClient buildClient(ProxySettings settings, {String? password}) {
    final HttpClient client = HttpClient()..idleTimeout = const Duration(seconds: 3);
    if (!settings.isUsable) return client;

    client.findProxy = (Uri uri) => settings.directiveFor(uri);

    final String username = settings.username.trim();
    if (settings.useAuth && username.isNotEmpty && password != null && password.isNotEmpty) {
      client.addProxyCredentials(
        settings.host.trim(),
        settings.port,
        '',
        HttpClientBasicCredentials(username, password),
      );
    }
    return client;
  }
}