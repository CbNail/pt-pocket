// 双通道选路（需求 #16）纯逻辑测试：
// 内网优先、失败回退外网、回网自动切回、缓存与失效、全失败抛出明确异常。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/config/app_config.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';

void main() {
  final Uri lan = Uri.parse('http://192.168.1.10:8000');
  final Uri wan = Uri.parse('https://pt.example.com');

  test('自动模式：内网可用时优先使用内网，且不探测外网', () async {
    final List<Uri> probed = <Uri>[];
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async {
        probed.add(candidate);
        return candidate == lan;
      },
      profile: EndpointProfile(lanBaseUrl: lan, wanBaseUrl: wan),
    );

    final ResolvedEndpoint endpoint = await resolver.resolve();

    expect(endpoint.link, ActiveLink.lan);
    expect(endpoint.baseUrl, lan);
    expect(probed, <Uri>[lan]);
    expect(resolver.activeLink, ActiveLink.lan);
  });

  test('自动模式：内网失败时回退外网', () async {
    final List<Uri> probed = <Uri>[];
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async {
        probed.add(candidate);
        return candidate == wan;
      },
      profile: EndpointProfile(lanBaseUrl: lan, wanBaseUrl: wan),
    );

    final ResolvedEndpoint endpoint = await resolver.resolve();

    expect(endpoint.link, ActiveLink.wan);
    expect(endpoint.baseUrl, wan);
    expect(probed, <Uri>[lan, wan]);
  });

  test('自动模式：缓存为外网后再次解析仍先探测内网，回到家网自动切回', () async {
    bool lanUp = false;
    DateTime now = DateTime(2026, 1, 1, 12);
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => candidate == lan ? lanUp : true,
      profile: EndpointProfile(lanBaseUrl: lan, wanBaseUrl: wan),
      clock: () => now,
    );

    expect((await resolver.resolve()).link, ActiveLink.wan);

    now = now.add(AppConfig.endpointCacheTtl);
    lanUp = true;

    expect((await resolver.resolve()).link, ActiveLink.lan);
    expect(resolver.activeLink, ActiveLink.lan);
  });

  test('强制外网模式跳过内网探测', () async {
    final List<Uri> probed = <Uri>[];
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async {
        probed.add(candidate);
        return true;
      },
      profile: EndpointProfile(lanBaseUrl: lan, wanBaseUrl: wan, mode: LinkMode.wan),
    );

    final ResolvedEndpoint endpoint = await resolver.resolve();

    expect(endpoint.link, ActiveLink.wan);
    expect(probed, <Uri>[wan]);
  });

  test('未过期缓存复用，不再重复探测；过期后重新探测', () async {
    int calls = 0;
    DateTime now = DateTime(2026, 1, 1, 12);
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async {
        calls++;
        return true;
      },
      profile: EndpointProfile(lanBaseUrl: lan, mode: LinkMode.lan),
      clock: () => now,
    );

    await resolver.resolve();
    await resolver.resolve();
    expect(calls, 1);

    now = now.add(AppConfig.endpointCacheTtl + const Duration(seconds: 1));
    await resolver.resolve();
    expect(calls, 2);
  });

  test('invalidate 后丢弃缓存并重新探测', () async {
    int calls = 0;
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async {
        calls++;
        return true;
      },
      profile: EndpointProfile(lanBaseUrl: lan, mode: LinkMode.lan),
    );

    await resolver.resolve();
    resolver.invalidate();
    expect(resolver.activeLink, ActiveLink.none);

    await resolver.resolve();
    expect(calls, 2);
  });

  test('两条通道均不可用时抛出 EndpointUnavailableException', () async {
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => false,
      profile: EndpointProfile(lanBaseUrl: lan, wanBaseUrl: wan),
    );

    await expectLater(
      resolver.resolve(),
      throwsA(
        isA<EndpointUnavailableException>().having(
          (EndpointUnavailableException e) => e.toString(),
          'toString',
          '内网与外网地址均不可用',
        ),
      ),
    );
  });

  test('尚未配置地址时抛出异常并提示未配置', () async {
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => true,
    );

    await expectLater(
      resolver.resolve(),
      throwsA(
        isA<EndpointUnavailableException>().having(
          (EndpointUnavailableException e) => e.toString(),
          'toString',
          '尚未配置 NAS 服务地址',
        ),
      ),
    );
  });
}