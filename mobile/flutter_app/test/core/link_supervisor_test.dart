// 链路守护测试：网络变化与周期复检都会让选路缓存失效，从而触发重新选路。

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/network/link_supervisor.dart';

void main() {
  final Uri lan = Uri.parse('http://192.168.1.10:8000');
  final Uri wan = Uri.parse('https://pt.example.com');

  test('网络变化时使选路缓存失效，下一次解析重新探测', () async {
    int calls = 0;
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async {
        calls++;
        return true;
      },
      profile: EndpointProfile(lanBaseUrl: lan, wanBaseUrl: wan),
    );
    final StreamController<List<ConnectivityResult>> changes =
        StreamController<List<ConnectivityResult>>();
    final LinkSupervisor supervisor = LinkSupervisor(
      resolver: resolver,
      changes: changes.stream,
      revalidateInterval: const Duration(hours: 1),
    );
    addTearDown(() {
      supervisor.dispose();
      changes.close();
    });

    supervisor.start();
    expect((await resolver.resolve()).link, ActiveLink.lan);
    expect(calls, 1);
    expect(resolver.cached, isNotNull);

    changes.add(<ConnectivityResult>[ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);

    expect(resolver.cached, isNull);
    expect((await resolver.resolve()).link, ActiveLink.lan);
    expect(calls, 2);
    expect(supervisor.revalidationCount, 1);
  });

  test('离开家庭网络后重新选路会回退到外网', () async {
    bool lanReachable = true;
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => candidate == lan ? lanReachable : true,
      profile: EndpointProfile(lanBaseUrl: lan, wanBaseUrl: wan),
    );
    final StreamController<List<ConnectivityResult>> changes =
        StreamController<List<ConnectivityResult>>();
    final LinkSupervisor supervisor = LinkSupervisor(
      resolver: resolver,
      changes: changes.stream,
      revalidateInterval: const Duration(hours: 1),
    );
    addTearDown(() {
      supervisor.dispose();
      changes.close();
    });

    supervisor.start();
    expect((await resolver.resolve()).link, ActiveLink.lan);

    lanReachable = false;
    changes.add(<ConnectivityResult>[ConnectivityResult.mobile]);
    await Future<void>.delayed(Duration.zero);

    expect((await resolver.resolve()).link, ActiveLink.wan);
  });

  test('start 幂等，dispose 后不再响应网络变化', () async {
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => true,
      profile: EndpointProfile(lanBaseUrl: lan),
    );
    final StreamController<List<ConnectivityResult>> changes =
        StreamController<List<ConnectivityResult>>();
    final LinkSupervisor supervisor = LinkSupervisor(
      resolver: resolver,
      changes: changes.stream,
      revalidateInterval: const Duration(hours: 1),
    );
    addTearDown(changes.close);

    supervisor.start();
    supervisor.start();
    expect(supervisor.isRunning, isTrue);

    supervisor.dispose();
    expect(supervisor.isRunning, isFalse);

    changes.add(<ConnectivityResult>[ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    expect(supervisor.revalidationCount, 0);
  });
}