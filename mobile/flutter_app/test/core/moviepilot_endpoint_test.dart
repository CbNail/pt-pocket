// MoviePilot 内外网双地址测试：旧数据迁移、双通道选路（内网优先、失败回退外网）。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';

void main() {
  const Map<String, dynamic> legacyLanInstance = <String, dynamic>{
    'id': 'mp1',
    'name': '本机 MP',
    'baseUrl': 'http://192.168.1.10:3000',
  };
  const Map<String, dynamic> legacyWanInstance = <String, dynamic>{
    'id': 'mp2',
    'name': '远程 MP',
    'baseUrl': 'https://mp.example.com:5888',
  };

  group('MpInstance 双地址', () {
    test('旧数据：内网地址归到 lan 通道', () {
      final MpInstance instance = MpInstance.fromJson(legacyLanInstance);

      expect(instance.lanBaseUrl, 'http://192.168.1.10:3000');
      expect(instance.wanBaseUrl, '');
      expect(instance.hasLan, isTrue);
      expect(instance.hasWan, isFalse);
      expect(instance.hasAnyAddress, isTrue);
      expect(instance.displayAddress, 'http://192.168.1.10:3000');
      expect(instance.addressSummary, '内网 http://192.168.1.10:3000');
    });

    test('旧数据：公网地址归到 wan 通道', () {
      final MpInstance instance = MpInstance.fromJson(legacyWanInstance);

      expect(instance.wanBaseUrl, 'https://mp.example.com:5888');
      expect(instance.lanBaseUrl, '');
      expect(instance.hasLan, isFalse);
      expect(instance.hasWan, isTrue);
      expect(instance.displayAddress, 'https://mp.example.com:5888');
    });

    test('双地址：按链路取地址，未配置的通道退回内网优先地址', () {
      final MpInstance instance = MpInstance.fromJson(<String, dynamic>{
        'id': 'mp3',
        'name': '双通道 MP',
        'lanBaseUrl': '192.168.1.10:3000',
        'wanBaseUrl': 'https://mp.example.com:5888',
      });

      expect(instance.hasLan, isTrue);
      expect(instance.hasWan, isTrue);
      expect(instance.addressFor(ActiveLink.lan), 'http://192.168.1.10:3000');
      expect(instance.addressFor(ActiveLink.wan), 'https://mp.example.com:5888');
      // 只有内网时，即使按外网取也退回内网地址，不会给出空地址
      expect(MpInstance.fromJson(legacyLanInstance).addressFor(ActiveLink.wan),
          'http://192.168.1.10:3000');
      expect(instance.addressSummary, contains('内网'));
      expect(instance.addressSummary, contains('外网'));
      expect(instance.host, '192.168.1.10');
    });

    test('序列化往返保留两条通道，且读取时统一归一化', () {
      final MpInstance instance = MpInstance.fromJson(<String, dynamic>{
        'id': 'mp4',
        'name': '往返',
        'lanBaseUrl': '192.168.1.10:3000/',
        'wanBaseUrl': 'https://mp.example.com:5888/',
      });
      expect(instance.lanUri.toString(), 'http://192.168.1.10:3000');
      expect(instance.wanUri.toString(), 'https://mp.example.com:5888');

      final MpInstance restored = MpInstance.fromJson(instance.toJson());
      expect(restored.id, 'mp4');
      expect(restored.name, '往返');
      expect(restored.hasLan, isTrue);
      expect(restored.hasWan, isTrue);
      expect(restored.lanUri.toString(), 'http://192.168.1.10:3000');
      expect(restored.wanUri.toString(), 'https://mp.example.com:5888');
    });

    test('没有任何地址时标记为未配置', () {
      final MpInstance instance = MpInstance.fromJson(<String, dynamic>{'id': 'mp5', 'name': '空'});

      expect(instance.hasAnyAddress, isFalse);
      expect(instance.addresses, isEmpty);
      expect(instance.addressSummary, '未配置地址');
    });

    test('copyWith 能单独更新某条通道', () {
      final MpInstance base = MpInstance.fromJson(legacyLanInstance);
      final MpInstance updated = base.copyWith(wanBaseUrl: 'https://mp.example.com');

      expect(updated.lanBaseUrl, 'http://192.168.1.10:3000');
      expect(updated.wanBaseUrl, 'https://mp.example.com');
      expect(updated.name, base.name);
    });
  });

  group('MP 双通道选路', () {
    EndpointResolver resolverWith(Set<String> reachableHosts) => EndpointResolver(
          // 与站点可达性探测同语义：能拿到响应（含 401/403）即视为该通道可用。
          probe: (Uri candidate, Duration timeout) async =>
              reachableHosts.contains(candidate.host),
          profile: EndpointProfile(
            lanBaseUrl: Uri.parse('http://192.168.1.10:3000'),
            wanBaseUrl: Uri.parse('https://mp.example.com:5888'),
          ),
        );

    test('内网可用时走内网', () async {
      final ResolvedEndpoint endpoint =
          await resolverWith(<String>{'192.168.1.10', 'mp.example.com'}).resolve();

      expect(endpoint.link, ActiveLink.lan);
      expect(endpoint.baseUrl.toString(), 'http://192.168.1.10:3000');
    });

    test('内网不通时回退外网', () async {
      final ResolvedEndpoint endpoint =
          await resolverWith(<String>{'mp.example.com'}).resolve();

      expect(endpoint.link, ActiveLink.wan);
      expect(endpoint.baseUrl.toString(), 'https://mp.example.com:5888');
    });

    test('两条通道都不通时明确抛出不可用', () async {
      final EndpointResolver resolver = resolverWith(<String>{});

      await expectLater(
        resolver.resolve(),
        throwsA(isA<EndpointUnavailableException>()),
      );
    });

    test('选路结果命中缓存，invalidate 后重新探测（回网自动切回内网）', () async {
      final Set<String> reachable = <String>{'mp.example.com'};
      final EndpointResolver resolver = resolverWith(reachable);

      expect((await resolver.resolve()).link, ActiveLink.wan);
      // 回到家庭网络：网络变化让缓存失效，下一次请求切回内网
      reachable.add('192.168.1.10');
      resolver.invalidate();

      expect((await resolver.resolve()).link, ActiveLink.lan);
    });
  });
}