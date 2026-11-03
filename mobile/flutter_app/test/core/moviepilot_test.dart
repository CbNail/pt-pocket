// MoviePilot 模型与适配注册表测试：促销归一化、版本适配能力、请求/结果解析与实例序列化。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/adapters/moviepilot_adapter_registry.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/models/service_health.dart';

void main() {
  test('促销类型归一化覆盖常见写法', () {
    expect(PromotionType.parse(''), PromotionType.none);
    expect(PromotionType.parse('normal'), PromotionType.none);
    expect(PromotionType.parse('免费'), PromotionType.free);
    expect(PromotionType.parse('Free'), PromotionType.free);
    expect(PromotionType.parse('50%'), PromotionType.half);
    expect(PromotionType.parse('2x免费'), PromotionType.twoXFree);
    expect(PromotionType.parse('2X Free'), PromotionType.twoXFree);
    expect(PromotionType.parse('2x50%'), PromotionType.twoXHalf);
    expect(PromotionType.parse('2x上传'), PromotionType.twoXUp);
    expect(PromotionType.parse('其它活动'), PromotionType.other);
    expect(PromotionType.parse('免费').isPromotion, isTrue);
  });

  test('MoviePilot 版本默认 v2，v3 已登记但未打通', () {
    expect(MpVersion.fromName('v3'), MpVersion.v3);
    expect(MpVersion.fromName(null), MpVersion.v2);
    expect(MoviePilotAdapterRegistry.defaultVersion, MpVersion.v2);

    final MpAdapterDescriptor v2 = MoviePilotAdapterRegistry.of(MpVersion.v2);
    expect(v2.supportsSearch, isTrue);
    expect(v2.supportsPush, isTrue);
    expect(v2.adapterId, 'moviepilot_v2');

    final MpAdapterDescriptor v3 = MoviePilotAdapterRegistry.of(MpVersion.v3);
    expect(v3.supportsSearch, isFalse);
    expect(v3.supportsPush, isFalse);
    expect(v3.note, contains('预留'));
  });

  test('搜索增强只挑选启用且适配器支持搜索的实例', () {
    const MpInstance v2On = MpInstance(
      id: 'm1',
      name: '主 MP',
      baseUrl: 'http://192.168.1.10:3000',
      version: MpVersion.v2,
      searchEnhance: true,
    );
    const MpInstance v3On = MpInstance(
      id: 'm2',
      name: '新 MP',
      baseUrl: 'http://192.168.1.11:3000',
      version: MpVersion.v3,
      searchEnhance: true,
    );
    const MpInstance v2Off = MpInstance(
      id: 'm3',
      name: '备用 MP',
      baseUrl: 'http://192.168.1.12:3000',
      version: MpVersion.v2,
      searchEnhance: false,
    );
    const MpInstance v2Disabled = MpInstance(
      id: 'm4',
      name: '停用 MP',
      baseUrl: 'http://192.168.1.13:3000',
      version: MpVersion.v2,
      searchEnhance: true,
      enabled: false,
    );

    expect(MoviePilotAdapterRegistry.canEnhanceSearch(v2On), isTrue);
    expect(MoviePilotAdapterRegistry.canEnhanceSearch(v3On), isFalse);
    expect(
      MoviePilotAdapterRegistry.enhanceInstanceIds(<MpInstance>[v2On, v3On, v2Off, v2Disabled]),
      <String>['m1'],
    );
  });

  test('搜索请求序列化与复制', () {
    const SearchRequest request = SearchRequest(
      keyword: '  关键词  ',
      siteIds: <String>['s1'],
      mpInstanceIds: <String>['m1'],
      promotion: PromotionFilter.twoXFree,
      sort: SortOption.size,
      page: 1,
      pageSize: 50,
    );

    final Map<String, dynamic> json = request.toJson();
    expect(json['keyword'], '关键词');
    expect(json['siteIds'], <String>['s1']);
    expect(json['mpInstanceIds'], <String>['m1']);
    expect(json['promotion'], 'twoXFree');
    expect(json['sort'], 'size');
    expect(request.isValid, isTrue);
    expect(request.copyWith(page: 2).page, 2);
    expect(const SearchRequest(keyword: '   ').isValid, isFalse);
  });

  test('搜索结果与分页结果解析容错', () {
    final SearchResultItem item = SearchResultItem.fromJson(<String, dynamic>{
      'torrentId': 't1',
      'name': '标题',
      'sizeBytes': '1073741824',
      'seedersCount': 3,
      'publishTime': '2026-10-01T12:00:00.000Z',
      'promotionType': '免费',
      'source': 'moviepilot',
    });

    expect(item.id, 't1');
    expect(item.title, '标题');
    expect(item.sizeBytes, 1073741824);
    expect(item.seeders, 3);
    expect(item.publishedAt, isNotNull);
    expect(item.promotion, PromotionType.free);
    expect(item.isFromMoviePilot, isTrue);

    final SearchPageResult result =
        SearchPageResult.fromJson(<String, dynamic>{}, requestedPage: 4);
    expect(result.items, isEmpty);
    expect(result.page, 4);
    expect(result.hasMore, isFalse);
  });

  test('MoviePilot 实例 JSON 往返保留全部字段', () {
    final MpInstance source = MpInstance(
      id: 'm1',
      name: '主 MP',
      baseUrl: 'http://192.168.1.10:3000',
      version: MpVersion.v2,
      credentialConfigured: true,
      searchEnhance: true,
      health: ServiceHealth.ok,
      lastTestedAt: DateTime.parse('2026-10-02T10:00:00.000Z'),
      createdAt: DateTime.parse('2026-10-01T10:00:00.000Z'),
    );

    final MpInstance restored = MpInstance.fromJson(source.toJson());

    expect(restored.id, 'm1');
    expect(restored.version, MpVersion.v2);
    expect(restored.credentialConfigured, isTrue);
    expect(restored.searchEnhance, isTrue);
    expect(restored.health, ServiceHealth.ok);
    expect(restored.host, '192.168.1.10');
    expect(restored.lastTestedAt, isNotNull);
  });
}