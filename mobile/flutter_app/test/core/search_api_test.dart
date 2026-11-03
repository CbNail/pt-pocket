// 聚合搜索与推送接口契约测试：请求参数、结果解析、部分成功与推送体。

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/services/search_api.dart';

import '../helpers/recording_adapter.dart';

void main() {
  late RecordingAdapter adapter;
  late SearchApi api;

  setUp(() {
    adapter = RecordingAdapter(<dynamic>[]);
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => true,
      profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
    );
    final ApiClient client = ApiClient(resolver: resolver);
    client.raw.httpClientAdapter = adapter;
    api = SearchApi(client: client);
  });

  test('搜索请求携带关键词、站点、MP 实例与分页参数', () async {
    adapter.payload = <String, dynamic>{
      'items': <dynamic>[
        <String, dynamic>{
          'id': 't1',
          'title': '某电影 2026 1080p',
          'siteId': 's1',
          'siteName': '站点一',
          'size': 1024,
          'seeders': 10,
          'leechers': 2,
          'promotion': '2xfree',
          'downloadUrl': 'http://nas.local/dl/1',
          'source': 'site',
        },
      ],
      'page': 1,
      'pageSize': 50,
      'hasMore': true,
      'siteErrors': <String, dynamic>{'站点二': '登录态失效'},
    };

    final SearchPageResult result = await api.search(
      const SearchRequest(
        keyword: ' 某电影 ',
        siteIds: <String>['s1', 's2'],
        mpInstanceIds: <String>['m1'],
        promotion: PromotionFilter.free,
        sort: SortOption.seeders,
        page: 2,
        pageSize: 20,
      ),
    );

    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.path, '/api/v1/search');

    final Map<String, dynamic> body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['keyword'], '某电影');
    expect(body['siteIds'], <String>['s1', 's2']);
    expect(body['mpInstanceIds'], <String>['m1']);
    expect(body['promotion'], 'free');
    expect(body['sort'], 'seeders');
    expect(body['page'], 2);
    expect(body['pageSize'], 20);

    expect(result.items, hasLength(1));
    expect(result.items.first.title, '某电影 2026 1080p');
    expect(result.items.first.promotion, PromotionType.twoXFree);
    expect(result.items.first.seeders, 10);
    expect(result.items.first.favoriteKey, 's1:t1');
    expect(result.hasMore, isTrue);
    expect(result.hasSiteErrors, isTrue);
    expect(result.siteErrors['站点二'], '登录态失效');
  });

  test('结果缺少分页字段时回退到请求分页参数', () async {
    adapter.payload = <String, dynamic>{
      'results': <dynamic>[
        <String, dynamic>{'torrentId': 't9', 'name': 'B', 'source': 'moviepilot'},
      ],
    };

    final SearchPageResult result = await api.search(
      const SearchRequest(keyword: 'B', page: 3, pageSize: 30),
    );

    expect(result.page, 3);
    expect(result.pageSize, 1);
    expect(result.items.single.id, 't9');
    expect(result.items.single.isFromMoviePilot, isTrue);
  });

  test('返回结构异常时抛出 ApiException 而不是静默空结果', () async {
    adapter.payload = <dynamic>[1, 2, 3];

    await expectLater(
      api.search(const SearchRequest(keyword: 'X')),
      throwsA(
        isA<Exception>().having(
          (Exception error) => error.toString(),
          'toString',
          contains('结构不符合预期'),
        ),
      ),
    );
  });

  test('推送请求携带下载器、保存目录与 MP 实例，空目录不发送', () async {
    await api.push(
      downloadUrl: 'http://nas.local/dl/1',
      downloaderId: 'd1',
      savePath: '/downloads/PT',
      category: 'pt',
      mpInstanceId: 'm1',
    );
    await api.push(downloadUrl: 'http://nas.local/dl/2', downloaderId: 'd1', savePath: '');

    expect(
      adapter.requests.map((RequestOptions r) => '${r.method} ${r.path}').toList(),
      <String>['POST /api/v1/torrents/push', 'POST /api/v1/torrents/push'],
    );

    final Map<String, dynamic> first = adapter.requests[0].data as Map<String, dynamic>;
    expect(first['downloadUrl'], 'http://nas.local/dl/1');
    expect(first['downloaderId'], 'd1');
    expect(first['savePath'], '/downloads/PT');
    expect(first['category'], 'pt');
    expect(first['mpInstanceId'], 'm1');

    final Map<String, dynamic> second = adapter.requests[1].data as Map<String, dynamic>;
    expect(second.containsKey('savePath'), isFalse);
    expect(second.containsKey('category'), isFalse);
  });
}