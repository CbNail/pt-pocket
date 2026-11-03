// 代理设置测试：可用性判断、内外网分流指令、JSON 往返与 Dio 适配器替换。
//
// 说明：dart:io 的 HttpClient 只暴露 findProxy 的 setter（无 getter），
// 因此代理指令的实际取值通过 ProxySettings.directiveFor 的逻辑测试覆盖。

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/proxy_settings.dart';
import 'package:pt_pocket/core/network/proxy_manager.dart';

void main() {
  const ProxySettings usable = ProxySettings(
    enabled: true,
    host: 'proxy.example.com',
    port: 7890,
  );

  test('地址与端口填写完整且启用时才算生效', () {
    expect(usable.isUsable, isTrue);
    expect(usable.endpoint, 'proxy.example.com:7890');
    expect(usable.summary, contains('HTTP 代理'));
    expect(const ProxySettings(enabled: true, host: 'proxy.example.com', port: 0).isUsable, isFalse);
    expect(const ProxySettings(enabled: false, host: 'proxy.example.com', port: 7890).isUsable, isFalse);
    expect(const ProxySettings(enabled: true, host: '  ', port: 7890).isUsable, isFalse);
  });

  test('外网请求走代理，内网与本机地址直连', () {
    const String proxy = 'PROXY proxy.example.com:7890';

    expect(usable.directiveFor(Uri.parse('https://pt.example.com')), proxy);
    expect(usable.directiveFor(Uri.parse('https://pt.example.com/index.php')), proxy);

    expect(usable.directiveFor(Uri.parse('http://192.168.1.10:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://10.0.0.5:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://172.16.5.5:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://172.31.5.5:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://100.64.1.2:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://127.0.0.1:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://nas:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://nas.local:8000')), 'DIRECT');
    expect(usable.directiveFor(Uri.parse('http://pve.lan:8000')), 'DIRECT');
  });

  test('172.32 之后与其它公网地址仍走代理', () {
    expect(
      usable.directiveFor(Uri.parse('http://172.32.5.5:8000')),
      'PROXY proxy.example.com:7890',
    );
    expect(
      usable.directiveFor(Uri.parse('http://203.0.113.9:8000')),
      'PROXY proxy.example.com:7890',
    );
  });

  test('未启用或未配置时全部直连', () {
    const ProxySettings off = ProxySettings(enabled: false, host: 'proxy.example.com', port: 7890);
    const ProxySettings incomplete = ProxySettings(enabled: true, host: '', port: 0);
    expect(off.directiveFor(Uri.parse('https://pt.example.com')), 'DIRECT');
    expect(incomplete.directiveFor(Uri.parse('https://pt.example.com')), 'DIRECT');
  });

  test('JSON 往返保留全部字段', () {
    const ProxySettings source = ProxySettings(
      enabled: true,
      host: 'p.example.com',
      port: 1080,
      useAuth: true,
      username: 'u1',
    );

    final ProxySettings restored = ProxySettings.fromJson(source.toJson());

    expect(restored.enabled, isTrue);
    expect(restored.type, ProxyType.http);
    expect(restored.host, 'p.example.com');
    expect(restored.port, 1080);
    expect(restored.useAuth, isTrue);
    expect(restored.username, 'u1');
  });

  test('套用代理后 Dio 换成 IO 适配器，并能按需构造 HttpClient', () {
    final Dio dio = Dio();
    ProxyManager.apply(dio, usable);

    final HttpClientAdapter adapter = dio.httpClientAdapter;
    expect(adapter, isA<IOHttpClientAdapter>());
    final HttpClient Function()? factory = (adapter as IOHttpClientAdapter).createHttpClient;
    expect(factory, isNotNull);

    final HttpClient client = factory!();
    expect(client, isA<HttpClient>());
    client.close(force: true);
  });

  test('未启用代理时构造的仍是可用 HttpClient', () {
    final HttpClient client = ProxyManager.buildClient(const ProxySettings());
    expect(client, isA<HttpClient>());
    client.close(force: true);
  });
}