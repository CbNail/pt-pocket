// 搜索实时展示测试（需求 5）：
// - 跨站合并后的统一排序口径；
// - 逐站检索的增量行为（每站完成即并入结果）、并发上限与中途停止；
// - 接口层把 cancelToken 透传下去（「停止」才真正中断在飞请求）；
// - 界面级：进度与结果同时可见、可停止、可查看每站状态。

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
// material 也有一个 SearchController（SearchAnchor 用），这里隐藏它，
// 避免与本项目的 SearchController 重名。
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/services/search_api.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:pt_pocket/core/storage/site_repository.dart';
import 'package:pt_pocket/features/search/search_page.dart';
import 'package:pt_pocket/features/search/search_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

SearchResultItem _item(String siteId, String id, {int seeders = 1, int sizeBytes = 100}) =>
    SearchResultItem(
      id: id,
      title: '$siteId-$id',
      siteId: siteId,
      siteName: siteId,
      sizeBytes: sizeBytes,
      seeders: seeders,
    );

SearchPageResult _page(List<SearchResultItem> items, {bool hasMore = false}) =>
    SearchPageResult(items: items, page: 1, pageSize: 50, hasMore: hasMore);

/// 可控的逐站检索桩：每站一个 Completer，测试据此观察「逐站回填」。
class _StubSearch {
  final List<String> requested = <String>[];
  final Map<String, Completer<SearchPageResult>> completers =
      <String, Completer<SearchPageResult>>{};

  Future<SearchPageResult> call(SearchRequest request, {CancelToken? cancelToken}) {
    final String siteId = request.siteIds.single;
    requested.add(siteId);
    return (completers[siteId] ??= Completer<SearchPageResult>()).future;
  }
}

/// 记录 RequestOptions 的适配器（不产生真实网络访问）。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.onFetch);

  final void Function(RequestOptions options) onFetch;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onFetch(options);
    return ResponseBody.fromString(
      '{"items":[]}',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 已配对的链路档案（搜索页据此不再提示先配对）。
class _ConfiguredEndpoint extends EndpointProfileNotifier {
  @override
  EndpointProfile build() => EndpointProfile(
        lanBaseUrl: Uri.parse('http://192.168.1.10:8000'),
        mode: LinkMode.auto,
      );
}

const List<PtSite> _twoSites = <PtSite>[
  PtSite(id: 's1', name: '站点一', baseUrl: 'https://a'),
  PtSite(id: 's2', name: '站点二', baseUrl: 'https://b'),
];

Future<ProviderContainer> _container(
  SharedPreferences prefs, {
  required List<PtSite> sites,
  required _StubSearch stub,
  bool configured = true,
}) async {
  final SiteRepository repository =
      SiteRepository(prefs: PrefsStore(prefs), secure: SecureStore());
  for (final PtSite site in sites) {
    await repository.upsert(site);
  }
  return ProviderContainer(
    overrides: <Override>[
      sharedPreferencesProvider.overrideWithValue(prefs),
      siteSearchFnProvider.overrideWithValue(stub.call),
      if (configured) endpointProfileProvider.overrideWith(_ConfiguredEndpoint.new),
    ],
  );
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    prefs = await SharedPreferences.getInstance();
  });

  group('跨站合并后的排序', () {
    final List<SearchResultItem> items = <SearchResultItem>[
      _item('a', '1', seeders: 5, sizeBytes: 300),
      _item('b', '2', seeders: 30, sizeBytes: 100),
      _item('c', '3', seeders: 5, sizeBytes: 200),
    ];

    test('按做种数降序', () {
      expect(
        sortSearchResults(items, SortOption.seeders).map((SearchResultItem i) => i.id),
        <String>['2', '1', '3'],
      );
    });

    test('按大小降序', () {
      expect(
        sortSearchResults(items, SortOption.size).map((SearchResultItem i) => i.id),
        <String>['1', '3', '2'],
      );
    });

    test('相关度保持插入次序（由后端决定），且不改动入参列表', () {
      final List<SearchResultItem> input = List<SearchResultItem>.of(items);
      expect(
        sortSearchResults(input, SortOption.relevance).map((SearchResultItem i) => i.id),
        <String>['1', '2', '3'],
      );
      expect(input.map((SearchResultItem i) => i.id), <String>['1', '2', '3']);
    });

    test('同键项次序稳定：重复排序结果一致', () {
      final List<SearchResultItem> once = sortSearchResults(items, SortOption.seeders);
      final List<SearchResultItem> twice = sortSearchResults(once, SortOption.seeders);
      expect(twice.map((SearchResultItem i) => i.id), once.map((SearchResultItem i) => i.id));
    });
  });

  group('逐站检索的增量行为', () {
    test('每站返回即并入结果，进度逐站更新', () async {
      final _StubSearch stub = _StubSearch();
      final ProviderContainer c =
          await _container(prefs, sites: _twoSites, stub: stub, configured: false);
      addTearDown(c.dispose);

      final Future<void> run = c.read(searchControllerProvider.notifier).submit('测试');
      await Future<void>.delayed(Duration.zero);

      final SearchState starting = c.read(searchControllerProvider);
      expect(starting.progress, hasLength(2));
      expect(starting.running, isTrue);
      expect(starting.receivedCount, 0);
      expect(starting.totalSites, 2);

      stub.completers['s1']!.complete(_page(<SearchResultItem>[_item('s1', '1')]));
      await Future<void>.delayed(Duration.zero);

      final SearchState afterFirst = c.read(searchControllerProvider);
      expect(afterFirst.receivedCount, 1, reason: '第一站返回后结果必须已经可见');
      expect(afterFirst.progress['s1']!.phase, SiteSearchPhase.success);
      expect(afterFirst.progress['s2']!.phase.isDone, isFalse);
      expect(afterFirst.doneSites, 1);
      expect(afterFirst.running, isTrue, reason: '还有站点在检索');

      stub.completers['s2']!.complete(_page(<SearchResultItem>[_item('s2', '2')]));
      await run;

      final SearchState done = c.read(searchControllerProvider);
      expect(done.running, isFalse);
      expect(done.stopped, isFalse);
      expect(done.receivedCount, 2);
      expect(done.doneSites, 2);
      expect(done.failedSites, isEmpty);
    });

    test('并发上限：同时最多 siteConcurrency 个请求在飞，完成一个再补一个', () async {
      final _StubSearch stub = _StubSearch();
      final List<PtSite> sites = <PtSite>[
        for (int i = 1; i <= 5; i++)
          PtSite(id: 's$i', name: '站点$i', baseUrl: 'https://s$i'),
      ];
      final ProviderContainer c =
          await _container(prefs, sites: sites, stub: stub, configured: false);
      addTearDown(c.dispose);

      final Future<void> run = c.read(searchControllerProvider.notifier).submit('测试');
      await Future<void>.delayed(Duration.zero);

      expect(stub.requested, hasLength(SearchController.siteConcurrency));
      final SearchState running = c.read(searchControllerProvider);
      expect(
        running.progress.values
            .where((SiteSearchStatus s) => s.phase == SiteSearchPhase.working)
            .length,
        SearchController.siteConcurrency,
      );
      expect(
        running.progress.values.where((SiteSearchStatus s) => s.phase == SiteSearchPhase.queued).length,
        5 - SearchController.siteConcurrency,
      );

      for (int i = 1; i <= 5; i++) {
        await Future<void>.delayed(Duration.zero);
        stub.completers['s$i']?.complete(_page(<SearchResultItem>[_item('s$i', '$i')]));
        await Future<void>.delayed(Duration.zero);
      }
      await run;

      final SearchState done = c.read(searchControllerProvider);
      expect(done.doneSites, 5);
      expect(done.receivedCount, 5);
      expect(stub.requested.toSet(), hasLength(5));
    });

    test('中途停止：保留已收到结果，未完成站点标记为已取消', () async {
      final _StubSearch stub = _StubSearch();
      final ProviderContainer c =
          await _container(prefs, sites: _twoSites, stub: stub, configured: false);
      addTearDown(c.dispose);

      final SearchController controller = c.read(searchControllerProvider.notifier);
      final Future<void> run = controller.submit('测试');
      await Future<void>.delayed(Duration.zero);

      stub.completers['s1']!.complete(_page(<SearchResultItem>[_item('s1', '1')]));
      await Future<void>.delayed(Duration.zero);

      await controller.stop();

      final SearchState stopped = c.read(searchControllerProvider);
      expect(stopped.running, isFalse);
      expect(stopped.stopped, isTrue);
      expect(stopped.receivedCount, 1, reason: '停止不应丢掉已收到的结果');
      expect(stopped.progress['s1']!.phase, SiteSearchPhase.success);
      expect(stopped.progress['s2']!.phase, SiteSearchPhase.cancelled);
      expect(stopped.notice, contains('已停止搜索'));

      // 补齐在飞请求，避免测试结束时留下未完成的 Future。
      stub.completers['s2']!.complete(_page(<SearchResultItem>[_item('s2', '2')]));
      await run;

      // 停止后迟到的结果不会写回状态。
      expect(c.read(searchControllerProvider).receivedCount, 1);
    });

    test('站点检索失败只影响该站，其它站结果照常呈现', () async {
      final _StubSearch stub = _StubSearch();
      final ProviderContainer c =
          await _container(prefs, sites: _twoSites, stub: stub, configured: false);
      addTearDown(c.dispose);

      final Future<void> run = c.read(searchControllerProvider.notifier).submit('测试');
      await Future<void>.delayed(Duration.zero);

      stub.completers['s1']!.complete(_page(<SearchResultItem>[_item('s1', '1')]));
      stub.completers['s2']!.completeError(
        DioException(
          requestOptions: RequestOptions(path: '/api/v1/search'),
          message: '站点拒绝访问',
        ),
      );
      await run;

      final SearchState done = c.read(searchControllerProvider);
      expect(done.receivedCount, 1);
      expect(done.progress['s1']!.phase, SiteSearchPhase.success);
      expect(done.progress['s2']!.phase, SiteSearchPhase.failed);
      expect(done.failedSites, hasLength(1));
      expect(done.notice, contains('检索失败'));
    });
  });

  group('接口层', () {
    test('搜索请求把 cancelToken 透传给底层请求（停止才能真正中断）', () async {
      final CancelToken token = CancelToken();
      RequestOptions? captured;
      final Dio dio = Dio()
        ..httpClientAdapter = _CapturingAdapter(
          (RequestOptions options) => captured = options,
        );
      final ApiClient client = ApiClient(
        dio: dio,
        resolver: EndpointResolver(
          probe: (Uri candidate, Duration timeout) async => true,
          profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
        ),
      );

      await SearchApi(client: client).search(
        const SearchRequest(keyword: 'x', siteIds: <String>['s1']),
        cancelToken: token,
      );

      expect(captured, isNotNull);
      expect(captured!.cancelToken, same(token));
      expect(captured!.path, '/api/v1/search');
    });
  });

  group('界面：进度与结果同时可见', () {
    testWidgets('搜索中显示进度并逐站出现结果，可停止、可看站点状态', (WidgetTester tester) async {
      final _StubSearch stub = _StubSearch();
      final ProviderContainer c = await _container(prefs, sites: _twoSites, stub: stub);
      addTearDown(c.dispose);

      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: SearchPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '测试');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      // 站点清单是异步加载的，先让它就绪再断言进度。
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 进度可见：已完成 0/2 站，结果还没到。
      expect(find.textContaining('搜索中：已完成 0/2 站'), findsOneWidget);
      expect(find.textContaining('已收到 0 条'), findsOneWidget);

      stub.completers['s1']!.complete(_page(<SearchResultItem>[_item('s1', '1')]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 结果已可见，同时进度仍在进行——这就是「实时展示」。
      expect(find.textContaining('s1-1'), findsOneWidget);
      expect(find.textContaining('搜索中：已完成 1/2 站'), findsOneWidget);
      expect(find.textContaining('已收到 1 条'), findsWidgets);

      // 搜索状态弹窗能看出每站结论。
      // 注意：检索中时进度条上有持续动画，pumpAndSettle 永远等不到静止，
      // 这里用按帧推进代替。
      await tester.tap(find.text('搜索状态'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('站点一'), findsOneWidget);
      expect(find.text('站点二'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('检索中'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 停止：保留已收到结果。
      await tester.tap(find.text('停止'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('已停止：已收到 1 条'), findsOneWidget);
      expect(find.textContaining('s1-1'), findsOneWidget);

      // 停止后迟到的结果不再写入。
      stub.completers['s2']!.complete(_page(<SearchResultItem>[_item('s2', '2')]));
      await tester.pumpAndSettle();
      expect(find.textContaining('s2-2'), findsNothing);
    });
  });
}