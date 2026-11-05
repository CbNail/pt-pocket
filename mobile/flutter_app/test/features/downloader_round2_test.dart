// 下载器模块第二轮改造测试：
// - 列表页：右上角视图切换（列表图 / 网格图）与「＋」添加入口，正文不再有添加入口；
// - 卡片数据：按直连采集的聚合统计口径，限速 / 剩余空间区分「未采集」与「不限」；
// - 引擎级状态：qBittorrent 的 server_state（剩余空间 / 全局限速）与版本；
// - 排版：统计网格按固定列数铺满，换行后的最后一行也补齐等宽空位；
// - 网格图：状态占比环 / 分类柱状 / 速率曲线。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pt_pocket/core/direct/downloader_gateway.dart';
import 'package:pt_pocket/core/direct/downloader_speed_history.dart';
import 'package:pt_pocket/core/direct/qbittorrent_client.dart';
import 'package:pt_pocket/core/direct/transmission_client.dart';
import 'package:pt_pocket/core/models/downloader.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/services/downloader_api.dart';
import 'package:pt_pocket/core/storage/app_keys.dart';
import 'package:pt_pocket/features/downloaders/downloader_detail_page.dart';
import 'package:pt_pocket/features/downloaders/downloader_providers.dart';
import 'package:pt_pocket/features/downloaders/downloaders_page.dart';
import 'package:pt_pocket/shared/widgets/mini_charts.dart';
import 'package:pt_pocket/shared/widgets/section_card.dart';
import 'package:pt_pocket/shared/widgets/stat_grid.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按路径分发响应的 qBittorrent 假后端（只覆盖本文件用到的接口）。
class _FakeQb implements HttpClientAdapter {
  _FakeQb(this.handlers);

  final Map<String, ResponseBody Function(RequestOptions options)> handlers;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final ResponseBody Function(RequestOptions)? handler = handlers[options.uri.path];
    if (handler == null) return ResponseBody.fromString('not found', 404);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _text(String body, {List<String>? cookies}) => ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/plain'],
        'set-cookie': ?cookies,
      },
    );

/// JSON 响应：内容类型必须是 application/json，Dio 才会按 `ResponseType.json` 解码。
ResponseBody _json(Object payload) => ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

/// 生成下载器索引的落盘内容（与 [DownloaderRepository] 的存储格式一致）。
String _downloaderIndex(List<Map<String, dynamic>> records) => jsonEncode(<String, dynamic>{
      'version': 1,
      'downloaders': records,
    });

const DownloaderConfig _qbConfig = DownloaderConfig(
  id: 'd1',
  name: 'qb 主下载器',
  kind: DownloaderKind.qbittorrent,
  baseUrl: 'http://192.168.1.10:8080',
  username: 'admin',
  credentialConfigured: true,
  isDefault: true,
);

final List<DownloaderTask> _tasks = <DownloaderTask>[
  const DownloaderTask(hash: 'h1', name: 'A', state: TaskState.seeding, category: 'pterclub'),
  const DownloaderTask(hash: 'h2', name: 'B', state: TaskState.seeding, category: 'pterclub'),
  const DownloaderTask(hash: 'h3', name: 'C', state: TaskState.downloading, category: 'hdhome'),
  const DownloaderTask(hash: 'h4', name: 'D', state: TaskState.error),
];

DownloaderApi _nasApi() => DownloaderApi(
      client: ApiClient(
        resolver: EndpointResolver(
          probe: (Uri candidate, Duration timeout) async => true,
          profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
        ),
      ),
    );

/// 受控的数据通道：把任务、统计与写操作全部拦在测试里，并记录下发过的操作。
class _FakeGateway extends DownloaderGateway {
  _FakeGateway(this.tasks)
      : super(
          () => false,
          (String id) => null,
          (String id) async => null,
          nas: _nasApi(),
          qb: QbittorrentClient(Dio()),
          tr: TransmissionClient(Dio()),
        );

  final List<DownloaderTask> tasks;
  final List<String> calls = <String>[];

  @override
  Future<List<DownloaderTask>> fetchTasks(String downloaderId, {CancelToken? cancelToken}) async =>
      tasks;

  @override
  Future<DownloaderTaskOption> fetchTaskOptions(String downloaderId) async =>
      const DownloaderTaskOption(
        categories: <String>['pterclub'],
        tags: <String>['官种'],
        paths: <String>['/downloads/pt'],
      );

  @override
  Future<void> addTorrentLinks(
    String downloaderId, {
    required List<String> links,
    String category = '',
    List<String> tags = const <String>[],
    String savePath = '',
    bool paused = false,
  }) async =>
      calls.add('addLinks:${links.join('|')}:$category:${tags.join(',')}:$savePath:$paused');

  @override
  Future<void> addTorrentFile(
    String downloaderId, {
    required List<int> bytes,
    required String filename,
    String category = '',
    List<String> tags = const <String>[],
    String savePath = '',
    bool paused = false,
  }) async =>
      calls.add('addFile:$filename:${bytes.length}:$category:${tags.join(',')}:$savePath:$paused');

  @override
  Future<QbTransferInfo?> fetchTransferInfo(String downloaderId) async => null;

  @override
  Future<DownloaderStats> fetchStats(String downloaderId) async => DownloaderStats.fromTasks(tasks);

  @override
  Future<void> pause(String downloaderId, List<String> hashes) async =>
      calls.add('pause:${hashes.join(',')}');

  @override
  Future<void> resume(String downloaderId, List<String> hashes) async =>
      calls.add('resume:${hashes.join(',')}');

  @override
  Future<void> remove(String downloaderId, List<String> hashes, {bool deleteFiles = false}) async =>
      calls.add('remove:${deleteFiles ? 'files' : 'record'}:${hashes.join(',')}');

  @override
  Future<void> setCategory(String downloaderId, List<String> hashes, String category) async =>
      calls.add('category:$category');

  @override
  Future<void> setTags(
    String downloaderId,
    List<String> hashes,
    List<String> tags, {
    String mode = 'add',
  }) async =>
      calls.add('tags:$mode:${tags.join(',')}');

  @override
  Future<void> setLocation(String downloaderId, List<String> hashes, String savePath) async =>
      calls.add('location:$savePath');

  @override
  Future<void> recheck(String downloaderId, List<String> hashes) async =>
      calls.add('recheck:${hashes.join(',')}');

  @override
  Future<void> reannounce(String downloaderId, List<String> hashes) async =>
      calls.add('reannounce:${hashes.join(',')}');

  @override
  Future<void> setForceStart(String downloaderId, List<String> hashes, bool enabled) async =>
      calls.add('forceStart:$enabled:${hashes.join(',')}');

  @override
  Future<void> setDownloadLimit(
    String downloaderId,
    List<String> hashes,
    int bytesPerSecond,
  ) async =>
      calls.add('downloadLimit:$bytesPerSecond');

  @override
  Future<void> setUploadLimit(
    String downloaderId,
    List<String> hashes,
    int bytesPerSecond,
  ) async =>
      calls.add('uploadLimit:$bytesPerSecond');

  @override
  Future<void> setAutoManaged(String downloaderId, List<String> hashes, bool enabled) async =>
      calls.add('autoManaged:$enabled');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  Future<ProviderContainer> container(
    List<Map<String, dynamic>> records, {
    DownloaderStats? stats,
    List<Override> extra = const <Override>[],
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ptp.${PrefKeys.downloaderIndex}': _downloaderIndex(records),
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final ProviderContainer scope = ProviderContainer(
      overrides: <Override>[
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (stats != null)
          downloaderStatsProvider.overrideWith((Ref ref, String downloaderId) async => stats),
        ...extra,
      ],
    );
    addTearDown(scope.dispose);
    return scope;
  }

  Future<void> pumpListPage(WidgetTester tester, ProviderContainer scope) async {
    final GoRouter router = GoRouter(
      initialLocation: '/downloaders',
      routes: <RouteBase>[
        GoRoute(
          path: '/downloaders',
          builder: (BuildContext context, GoRouterState state) => const DownloadersPage(),
        ),
        GoRoute(
          path: '/downloaders/add',
          builder: (BuildContext context, GoRouterState state) => const Scaffold(body: Text('添加页')),
        ),
        GoRoute(
          path: '/downloaders/detail',
          builder: (BuildContext context, GoRouterState state) => DownloaderDetailPage(
            downloaderId: state.uri.queryParameters['downloaderId'] ?? '',
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('下载器列表页：视图切换与添加入口', () {
    testWidgets('右上角有视图切换与「＋」，正文没有添加入口', (WidgetTester tester) async {
      final ProviderContainer scope = await container(<Map<String, dynamic>>[
        _qbConfig.toJson(),
        const DownloaderConfig(
          id: 'd2',
          name: 'tr',
          kind: DownloaderKind.transmission,
          baseUrl: 'http://192.168.1.10:9091',
        ).toJson(),
      ]);
      await pumpListPage(tester, scope);

      // 右上角三个入口：视图切换、刷新、＋ 添加下载器。
      expect(find.byIcon(Icons.grid_view_outlined), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);

      // 「＋ 添加下载器」这类悬浮入口已从正文移除。
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('切换按钮在列表图与网格图之间切换，并落盘', (WidgetTester tester) async {
      final ProviderContainer scope = await container(<Map<String, dynamic>>[_qbConfig.toJson()]);
      await pumpListPage(tester, scope);

      await tester.tap(find.byIcon(Icons.grid_view_outlined));
      await tester.pumpAndSettle();

      expect(find.byType(GridView), findsOneWidget);
      expect(find.byIcon(Icons.view_list_outlined), findsOneWidget);
      expect(scope.read(prefsStoreProvider).getString(PrefKeys.downloadersViewMode), 'grid');

      await tester.tap(find.byIcon(Icons.view_list_outlined));
      await tester.pumpAndSettle();

      expect(find.byType(GridView), findsNothing);
      expect(find.byIcon(Icons.grid_view_outlined), findsOneWidget);
      expect(scope.read(prefsStoreProvider).getString(PrefKeys.downloadersViewMode), 'list');
    });

    testWidgets('空清单只提示去右上角添加，不再内嵌添加按钮', (WidgetTester tester) async {
      final ProviderContainer scope = await container(<Map<String, dynamic>>[]);
      await pumpListPage(tester, scope);

      expect(find.text('还没有添加下载器'), findsOneWidget);
      expect(find.textContaining('右上角「＋」'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget); // 只剩右上角那一个
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('下载器统计口径', () {
    test('fromTasks 统计各状态与分类，未分类的任务单独归并', () {
      final DownloaderStats stats = DownloaderStats.fromTasks(_tasks);

      expect(stats.total, 4);
      expect(stats.countOf(TaskState.seeding), 2);
      expect(stats.countOf(TaskState.downloading), 1);
      expect(stats.countOf(TaskState.error), 1);
      expect(stats.countOf(TaskState.completed), 0);
      expect(stats.categoryCounts['pterclub'], 2);
      expect(stats.categoryCounts['hdhome'], 1);
      expect(stats.categoryCounts['未分类'], 1);
      expect(stats.sampled, isTrue);
    });

    test('限速 0 = 不限，缺失 = 未采集，两者不混为一谈', () {
      expect(downloaderLimitLabel(null), '未采集');
      expect(downloaderLimitLabel(0), '不限');
      expect(downloaderLimitLabel(1048576), '1.0 MB/s');
    });

    test('卡片固定 12 项数据，顺序稳定（4 行 × 3 列铺满）', () {
      final List<StatItem> items = downloaderStatItems(DownloaderStats.fromTasks(_tasks));
      expect(items, hasLength(12));
      expect(
        items.map((StatItem i) => i.label).toList(growable: false),
        <String>[
          '种子总数',
          '正在做种',
          '正在下载',
          '已完成',
          '已暂停',
          '排队中',
          '校验中',
          '错误',
          '未知',
          '上传限速',
          '下载限速',
          '剩余空间',
        ],
      );
      // 未采集的引擎字段显示「未采集」，不显示 0。
      expect(items.last.value, '未采集');
      expect(items.last.collected, isFalse);
    });
  });

  group('qBittorrent 引擎级状态', () {
    QbittorrentClient clientWith(HttpClientAdapter adapter) {
      final Dio dio = Dio();
      dio.httpClientAdapter = adapter;
      return QbittorrentClient(dio);
    }

    test('server_state 的剩余空间与全局限速被读到', () async {
      final _FakeQb adapter = _FakeQb(<String, ResponseBody Function(RequestOptions)>{
        '/api/v2/auth/login': (RequestOptions options) =>
            _text('Ok.', cookies: <String>['SID=abc123; path=/']),
        '/api/v2/app/version': (RequestOptions options) => _text('4.6.7'),
        '/api/v2/transfer/info': (RequestOptions options) => _json(<String, dynamic>{
          'dl_info_speed': 2048,
          'up_info_speed': 1024,
          'dl_info_data': 10,
          'up_info_data': 20,
        }),
        '/api/v2/sync/maindata': (RequestOptions options) => _json(<String, dynamic>{
          'server_state': <String, dynamic>{
            'free_space_on_disk': 123456789,
            'dl_rate_limit': 1048576,
            'up_rate_limit': 0,
          },
        }),
      });

      final QbTransferInfo info = await clientWith(adapter).fetchTransferInfo(
        _qbConfig,
        credential: <String, dynamic>{'password': 'pw'},
      );

      expect(info.version, '4.6.7');
      expect(info.downloadSpeed, 2048);
      expect(info.uploadSpeed, 1024);
      expect(info.freeSpaceBytes, 123456789);
      expect(info.downloadLimitBytes, 1048576);
      // 限速 0 表示「不限」，与「未采集」不是一回事。
      expect(info.uploadLimitBytes, 0);
    });

    test('取不到 server_state 时是「未采集」而不是 0', () async {
      final _FakeQb adapter = _FakeQb(<String, ResponseBody Function(RequestOptions)>{
        '/api/v2/auth/login': (RequestOptions options) =>
            _text('Ok.', cookies: <String>['SID=abc123; path=/']),
        '/api/v2/transfer/info': (RequestOptions options) => _json(<String, dynamic>{
          'dl_info_speed': 0,
          'up_info_speed': 0,
        }),
      });

      final QbTransferInfo info = await clientWith(adapter).fetchTransferInfo(
        _qbConfig,
        credential: <String, dynamic>{'password': 'pw'},
      );

      expect(info.freeSpaceBytes, isNull);
      expect(info.downloadLimitBytes, isNull);
      expect(info.uploadLimitBytes, isNull);
      expect(info.version, '');
    });
  });

  group('统计网格排版', () {
    Future<void> pumpGrid(WidgetTester tester, List<StatItem> items) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: StatGrid(items: items)),
      ));
      await tester.pumpAndSettle();
    }

    List<Row> rowsOf(WidgetTester tester) =>
        tester.widgetList<Row>(find.byType(Row)).toList(growable: false);

    testWidgets('12 项数据正好 4 行，每行 3 格', (WidgetTester tester) async {
      final List<StatItem> items = downloaderStatItems(DownloaderStats.fromTasks(_tasks));
      await pumpGrid(tester, items);

      final List<Row> rows = rowsOf(tester);
      expect(rows, hasLength(4));
      for (final Row row in rows) {
        expect(row.children, hasLength(3));
      }
    });

    testWidgets('条目数不足一行时，最后一行补齐等宽空位', (WidgetTester tester) async {
      await pumpGrid(tester, const <StatItem>[
        StatItem(label: 'A', value: '1'),
        StatItem(label: 'B', value: '2'),
        StatItem(label: 'C', value: '3'),
        StatItem(label: 'D', value: '4'),
        StatItem(label: 'E', value: '5'),
        StatItem(label: 'F', value: '6'),
        StatItem(label: 'G', value: '7'),
      ]);

      final List<Row> rows = rowsOf(tester);
      expect(rows, hasLength(3));
      for (final Row row in rows) {
        expect(row.children, hasLength(3)); // 最后一行 2 个空位也是等宽的
      }
    });
  });

  group('列表图数据与网格图图表', () {
    testWidgets('列表图按 12 项数据网格展示，未采集字段写明「未采集」', (WidgetTester tester) async {
      final ProviderContainer scope = await container(
        <Map<String, dynamic>>[_qbConfig.toJson()],
        stats: DownloaderStats.fromTasks(_tasks, version: '4.6.7'),
      );
      await pumpListPage(tester, scope);

      expect(find.text('种子总数'), findsOneWidget);
      expect(find.text('正在做种'), findsOneWidget);
      expect(find.text('剩余空间'), findsOneWidget);
      // 引擎没给剩余空间与限速：三项都显示「未采集」而不是 0。
      expect(find.text('未采集'), findsNWidgets(3));
      expect(find.text('v4.6.7'), findsOneWidget);
    });

    testWidgets('网格图给出占比环、分类柱状与速率曲线', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ptp.${PrefKeys.downloaderIndex}': _downloaderIndex(<Map<String, dynamic>>[_qbConfig.toJson()]),
        'ptp.${PrefKeys.downloadersViewMode}': 'grid',
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final DownloaderStats stats = DownloaderStats.fromTasks(
        _tasks,
        downloadSpeed: 1024,
        uploadSpeed: 512,
      );
      final ProviderContainer scope = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
          downloaderStatsProvider.overrideWith((Ref ref, String downloaderId) async => stats),
        ],
      );
      addTearDown(scope.dispose);

      // 采样两点以上，速率曲线才真的画线。
      final DownloaderSpeedHistory history = scope.read(downloaderSpeedHistoryProvider);
      history.record('d1', 512, 256);
      history.record('d1', 1024, 512);

      await pumpListPage(tester, scope);

      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(MiniDonut), findsOneWidget);
      expect(find.byType(MiniBarChart), findsOneWidget);
      expect(find.byType(MiniSparkline), findsOneWidget);
      expect(find.text('种子'), findsOneWidget);
      // 速率来自统计，图表来自采样：两者都按真实值展示。
      expect(find.text('↓ 1.0 KB/s'), findsOneWidget);
    });
  });

  group('任务页左滑与多选', () {
    final List<DownloaderTask> tasks = <DownloaderTask>[
      const DownloaderTask(hash: 'h1', name: '任务甲', state: TaskState.downloading),
      const DownloaderTask(hash: 'h2', name: '任务乙', state: TaskState.paused),
    ];

    Future<(ProviderContainer, _FakeGateway)> openDetail(WidgetTester tester) async {
      final _FakeGateway gateway = _FakeGateway(tasks);
      final ProviderContainer scope = await container(
        <Map<String, dynamic>>[_qbConfig.toJson()],
        extra: <Override>[downloaderGatewayProvider.overrideWithValue(gateway)],
      );
      await pumpListPage(tester, scope);
      await tester.tap(find.text('qb 主下载器'));
      await tester.pumpAndSettle();
      return (scope, gateway);
    }

    testWidgets('左滑露出「暂停 / 删除」，点暂停下发到该条任务', (WidgetTester tester) async {
      final (ProviderContainer _, _FakeGateway gateway) = await openDetail(tester);
      expect(find.text('任务甲'), findsOneWidget);

      final double before = tester.getTopLeft(find.text('任务甲')).dx;
      await tester.drag(find.text('任务甲'), const Offset(-260, 0));
      await tester.pumpAndSettle();

      final double after = tester.getTopLeft(find.text('任务甲')).dx;
      expect(after, lessThan(before - 100), reason: '左滑后卡片应被推开，露出背后的操作按钮');
      // 左滑动作按该任务当前状态给：甲是「暂停」、乙是「继续」；删除各一条。
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('删除'), findsNWidgets(2));

      await tester.tap(find.text('暂停').first);
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('pause:h1'));
    });

    testWidgets('删除任务前先弹确认，取消则不下发', (WidgetTester tester) async {
      final (ProviderContainer _, _FakeGateway gateway) = await openDetail(tester);

      await tester.drag(find.text('任务甲'), const Offset(-260, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();

      expect(find.text('移除任务'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.calls, isEmpty);

      await tester.drag(find.text('任务甲'), const Offset(-260, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅移除任务'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('remove:record:h1'));
    });

    testWidgets('长按进入多选，可全选并批量暂停', (WidgetTester tester) async {
      final (ProviderContainer _, _FakeGateway gateway) = await openDetail(tester);

      await tester.longPress(find.text('任务甲'));
      await tester.pumpAndSettle();

      // 进入多选：左上角变成退出多选（✕），底部出现批量操作条。
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('已选 1 条'), findsOneWidget);

      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 条'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '暂停'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('pause:h1,h2'));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 条'), findsNothing);
    });
  });

  group('任务页筛选面板', () {
    final List<DownloaderTask> tasks = <DownloaderTask>[
      const DownloaderTask(
        hash: 'h1',
        name: '任务甲',
        state: TaskState.downloading,
        category: 'pterclub',
        tags: <String>['官种'],
        savePath: '/downloads/pt',
        tracker: 'tracker.a.com',
      ),
      const DownloaderTask(
        hash: 'h2',
        name: '任务乙',
        state: TaskState.seeding,
        category: 'hdhome',
        tags: <String>['免费'],
        savePath: '/downloads/hd',
        tracker: 'tracker.b.com',
      ),
    ];

    Future<void> openSheet(WidgetTester tester) async {
      final ProviderContainer scope = await container(
        <Map<String, dynamic>>[_qbConfig.toJson()],
        extra: <Override>[downloaderGatewayProvider.overrideWithValue(_FakeGateway(tasks))],
      );
      await pumpListPage(tester, scope);
      await tester.tap(find.text('qb 主下载器'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
    }

    testWidgets('三横线面板覆盖状态 / 分类 / 标签 / 路径 / 服务器 / 排序', (WidgetTester tester) async {
      await openSheet(tester);

      expect(find.text('筛选'), findsOneWidget);
      for (final String section in <String>['状态', '分类', '标签', '路径', '服务器', '排序']) {
        expect(find.text(section), findsWidgets);
      }
      // 只列出任务里真实存在的取值，并带上数量。
      expect(find.widgetWithText(FilterChip, 'pterclub (1)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, '下载中 (1)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, '官种 (1)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, '/downloads/hd (1)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'tracker.b.com (1)'), findsOneWidget);
    });

    testWidgets('按分类筛选只剩对应任务，摘要写明生效条件', (WidgetTester tester) async {
      await openSheet(tester);

      final Finder chip = find.widgetWithText(FilterChip, 'pterclub (1)');
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(find.text('任务甲'), findsOneWidget);
      expect(find.text('任务乙'), findsNothing);
      expect(find.textContaining('筛选出 1 条'), findsOneWidget);
      // 摘要行把生效条件写全（任务卡片上也有「分类 pterclub」，所以要断言整行文案）。
      expect(find.text('筛选出 1 条 / 共 2 条 · 分类 pterclub'), findsOneWidget);
      // 有筛选生效时三横线上带角标。
      expect(find.byType(Badge), findsOneWidget);
    });

    testWidgets('状态与标签可以叠加筛选，重置后恢复全部', (WidgetTester tester) async {
      await openSheet(tester);

      await tester.tap(find.widgetWithText(FilterChip, '做种中 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('任务甲'), findsNothing);
      expect(find.text('任务乙'), findsOneWidget);

      final Finder tag = find.widgetWithText(FilterChip, '免费 (1)');
      await tester.ensureVisible(tag);
      await tester.pumpAndSettle();
      await tester.tap(tag);
      await tester.pumpAndSettle();
      // 状态=做种中 且 标签=免费：仍只剩乙。
      expect(find.text('任务乙'), findsOneWidget);
      expect(find.textContaining('状态 做种中'), findsOneWidget);
      expect(find.textContaining('标签 免费'), findsOneWidget);

      final Finder reset = find.text('重置');
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(find.text('任务甲'), findsOneWidget);
      expect(find.text('任务乙'), findsOneWidget);
      expect(find.textContaining('共 2 条任务'), findsOneWidget);
    });
  });

  group('任务页操作菜单', () {
    final List<DownloaderTask> tasks = <DownloaderTask>[
      const DownloaderTask(
        hash: 'h1',
        name: '任务甲',
        state: TaskState.downloading,
        magnetUri: 'magnet:?xt=urn:btih:h1',
        savePath: '/downloads/pt',
      ),
      const DownloaderTask(
        hash: 'h2',
        name: '任务乙',
        state: TaskState.paused,
        magnetUri: 'magnet:?xt=urn:btih:h2',
      ),
    ];

    Future<_FakeGateway> open(WidgetTester tester, {DownloaderConfig config = _qbConfig}) async {
      final _FakeGateway gateway = _FakeGateway(tasks);
      final ProviderContainer scope = await container(
        <Map<String, dynamic>>[config.toJson()],
        extra: <Override>[downloaderGatewayProvider.overrideWithValue(gateway)],
      );
      await pumpListPage(tester, scope);
      await tester.tap(find.text(config.name));
      await tester.pumpAndSettle();
      return gateway;
    }

    /// 某张任务卡片右上角的三个点（避开顶部那个）。
    Finder cardMenu(String name) => find.descendant(
          of: find.ancestor(of: find.text(name), matching: find.byType(SectionCard)).first,
          matching: find.byIcon(Icons.more_vert),
        );

    testWidgets('卡片三个点给出全部任务操作项，并写明引擎不支持的项目', (WidgetTester tester) async {
      await open(tester);
      await tester.tap(cardMenu('任务甲'));
      await tester.pumpAndSettle();

      expect(find.text('更改路径'), findsOneWidget);
      expect(find.text('更改分类'), findsOneWidget);
      expect(find.text('编辑标签'), findsOneWidget);
      expect(find.text('种子限速'), findsOneWidget);
      expect(find.text('复制种子哈希'), findsOneWidget);
      expect(find.text('复制磁力链接'), findsOneWidget);
      expect(find.text('重新汇报'), findsOneWidget);
      expect(find.text('重新校验'), findsOneWidget);
      expect(find.text('强制继续'), findsOneWidget);
      // qBittorrent 没有自动种子管理：该项不可点，并写明原因。
      expect(find.text('自动种子管理（该下载器不支持）'), findsOneWidget);
    });

    testWidgets('重新汇报 / 重新校验 / 强制继续下发到该任务', (WidgetTester tester) async {
      final _FakeGateway gateway = await open(tester);

      await tester.tap(cardMenu('任务甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新汇报'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('reannounce:h1'));

      await tester.tap(cardMenu('任务甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新校验'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('recheck:h1'));

      await tester.tap(cardMenu('任务甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.ancestor(
        of: find.text('强制继续'),
        matching: find.byType(CheckedPopupMenuItem<String>),
      ).first);
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('forceStart:true:h1'));
    });

    testWidgets('种子限速按 KB/s 下发到下载与上传', (WidgetTester tester) async {
      final _FakeGateway gateway = await open(tester);

      await tester.tap(cardMenu('任务甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('种子限速'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '下载限速（KB/s）'), '512');
      await tester.enterText(find.widgetWithText(TextField, '上传限速（KB/s）'), '0');
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();

      expect(gateway.calls, contains('downloadLimit:${512 * 1024}'));
      expect(gateway.calls, contains('uploadLimit:0'));
    });

    testWidgets('复制种子哈希写进剪贴板并给出反馈', (WidgetTester tester) async {
      final List<MethodCall> platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await open(tester);
      await tester.tap(cardMenu('任务甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制种子哈希'));
      await tester.pumpAndSettle();

      final MethodCall setData = platformCalls.firstWhere(
        (MethodCall call) => call.method == 'Clipboard.setData',
      );
      expect((setData.arguments as Map<Object?, Object?>)['text'], 'h1');
      expect(find.text('已复制种子哈希'), findsOneWidget);
    });

    testWidgets('Transmission：分类项明确不可用，自动种子管理可用', (WidgetTester tester) async {
      await open(
        tester,
        config: const DownloaderConfig(
          id: 'tr-1',
          name: 'tr 主下载器',
          kind: DownloaderKind.transmission,
          baseUrl: 'http://192.168.1.10:9091',
        ),
      );

      await tester.tap(cardMenu('任务甲'));
      await tester.pumpAndSettle();
      expect(find.text('更改分类（该下载器不支持）'), findsOneWidget);
      expect(find.text('自动种子管理…'), findsOneWidget);
    });

    testWidgets('多选后顶部菜单对选中任务批量生效', (WidgetTester tester) async {
      final _FakeGateway gateway = await open(tester);

      await tester.longPress(find.text('任务甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 条'), findsOneWidget);

      // 多选状态下卡片上的三个点已隐藏，只剩顶部菜单。
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      expect(find.text('复制种子哈希（仅单个任务）'), findsOneWidget);
      await tester.tap(find.text('重新汇报'));
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('reannounce:h1,h2'));
    });
  });

  group('任务页添加任务', () {
    final List<DownloaderTask> tasks = <DownloaderTask>[
      const DownloaderTask(hash: 'h1', name: '任务甲', state: TaskState.downloading),
    ];

    Future<_FakeGateway> open(WidgetTester tester, {DownloaderConfig config = _qbConfig}) async {
      // 添加面板较高：把测试视口放高，避免「添加」按钮落在屏幕外（默认 800×600）。
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final _FakeGateway gateway = _FakeGateway(tasks);
      final ProviderContainer scope = await container(
        <Map<String, dynamic>>[config.toJson()],
        extra: <Override>[downloaderGatewayProvider.overrideWithValue(gateway)],
      );
      await pumpListPage(tester, scope);
      await tester.tap(find.text(config.name));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      return gateway;
    }

    testWidgets('右上角「＋」打开面板：链接 / 文件 / 自动管理 / 分类 / 标签 / 路径 / 暂停都在', (
      WidgetTester tester,
    ) async {
      await open(tester);

      expect(find.text('添加任务 · qBittorrent'), findsOneWidget);
      expect(find.widgetWithText(TextField, '种子链接'), findsOneWidget);
      expect(find.text('种子文件：点击右侧按钮添加'), findsOneWidget);
      expect(find.text('自动种子管理'), findsOneWidget);
      expect(find.text('添加分类'), findsOneWidget);
      expect(find.text('添加标签'), findsOneWidget);
      expect(find.text('保存路径'), findsOneWidget);
      expect(find.text('添加后暂停'), findsOneWidget);
      // qBittorrent 没有自动种子管理开关：写明原因且不可切换。
      expect(find.text('该下载器不支持（qBittorrent 用队列与优先级管理）'), findsOneWidget);
    });

    testWidgets('填链接 + 选分类标签 + 勾暂停后添加，按所选参数下发', (WidgetTester tester) async {
      final _FakeGateway gateway = await open(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '种子链接'),
        'magnet:?xt=urn:btih:a\n\n magnet:?xt=urn:btih:b ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'pterclub'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '官种'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加后暂停'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(
        gateway.calls,
        contains('addLinks:magnet:?xt=urn:btih:a|magnet:?xt=urn:btih:b:pterclub:官种::true'),
      );
      expect(find.textContaining('已向「qb 主下载器」提交 2 个任务'), findsOneWidget);
    });

    testWidgets('任务卡片指标用 3 列等宽网格，行行铺满', (WidgetTester tester) async {
      final _FakeGateway gateway = _FakeGateway(tasks);
      final ProviderContainer scope = await container(
        <Map<String, dynamic>>[_qbConfig.toJson()],
        extra: <Override>[downloaderGatewayProvider.overrideWithValue(gateway)],
      );
      await pumpListPage(tester, scope);
      await tester.tap(find.text('qb 主下载器'));
      await tester.pumpAndSettle();

      // 任务卡片里的指标走统一的等宽统计网格（三列一行，行行铺满）。
      final Finder cardGrid = find.byType(StatGrid);
      expect(cardGrid, findsOneWidget);
      for (final String label in <String>['下载', '上传', '剩余', '分享率', '分类', '服务器']) {
        expect(find.descendant(of: cardGrid, matching: find.text(label)), findsOneWidget);
      }
      final List<Row> rows = tester
          .widgetList<Row>(find.descendant(of: cardGrid, matching: find.byType(Row)))
          .toList(growable: false);
      expect(rows, hasLength(2));
      for (final Row row in rows) {
        expect(row.children, hasLength(3));
      }
    });

    testWidgets('空提交时提示先填链接或选文件，不发起添加', (WidgetTester tester) async {
      final _FakeGateway gateway = await open(tester);

      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(find.text('请填种子链接，或选择一个种子文件'), findsOneWidget);
      expect(gateway.calls, isEmpty);
    });

    testWidgets('Transmission：自动种子管理可开关，关闭后手动项才可用', (WidgetTester tester) async {
      await open(
        tester,
        config: const DownloaderConfig(
          id: 'tr-1',
          name: 'tr 主下载器',
          kind: DownloaderKind.transmission,
          baseUrl: 'http://192.168.1.10:9091',
        ),
      );

      expect(find.text('该下载器不支持分类（Transmission 只有标签）'), findsOneWidget);
      // 自动种子管理默认开启 → 手动保存路径 / 标签不可用。
      expect(find.text('手动设定需关闭自动种子管理'), findsWidgets);

      await tester.tap(find.text('自动种子管理'));
      await tester.pumpAndSettle();
      expect(find.text('手动设定需关闭自动种子管理'), findsNothing);
    });
  });
}