// 下载器管理能力测试（需求 3）：
// - 默认下载器标记的互斥收敛与迁移补齐；
// - 任务的筛选 / 排序口径；
// - 新增任务操作（分类 / 标签 / 路径 / 可选值）的接口路径与请求体；
// - 界面级：左滑露出「编辑 / 删除 / 默认」三个动作并可用；任务页不再展示连接信息与操作框。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pt_pocket/core/models/downloader.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/router/app_routes.dart';
import 'package:pt_pocket/core/services/downloader_api.dart';
import 'package:pt_pocket/core/storage/app_keys.dart';
import 'package:pt_pocket/core/storage/downloader_repository.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:pt_pocket/features/downloaders/downloader_detail_page.dart';
import 'package:pt_pocket/features/downloaders/downloader_providers.dart';
import 'package:pt_pocket/features/downloaders/downloaders_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.payload);

  Object? payload;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(payload ?? <String, dynamic>{}),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late PrefsStore prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    prefs = PrefsStore(await SharedPreferences.getInstance());
  });

  group('默认下载器标记', () {
    DownloaderRepository repo() =>
        DownloaderRepository(prefs: prefs, secure: SecureStore());

    test('第一条自动成为默认，后续新增不会抢走默认', () async {
      final DownloaderRepository r = repo();
      await r.upsert(const DownloaderConfig(
        id: 'd1',
        name: 'A',
        kind: DownloaderKind.qbittorrent,
        baseUrl: 'http://a:1',
      ));
      await r.upsert(const DownloaderConfig(
        id: 'd2',
        name: 'B',
        kind: DownloaderKind.transmission,
        baseUrl: 'http://b:2',
      ));

      final List<DownloaderConfig> list = r.loadAll();
      expect(list.map((DownloaderConfig d) => d.isDefault), <bool>[true, false]);
    });

    test('设为默认是互斥的，切换后旧默认自动取消', () async {
      final DownloaderRepository r = repo();
      await r.upsert(const DownloaderConfig(id: 'd1', name: 'A', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:1'));
      await r.upsert(const DownloaderConfig(id: 'd2', name: 'B', kind: DownloaderKind.qbittorrent, baseUrl: 'http://b:2'));
      await r.upsert(const DownloaderConfig(id: 'd3', name: 'C', kind: DownloaderKind.qbittorrent, baseUrl: 'http://c:3'));

      await r.setDefault('d3');

      final List<DownloaderConfig> list = r.loadAll();
      expect(list.map((DownloaderConfig d) => d.isDefault), <bool>[false, false, true]);
      // 既有字段不因设默认而丢失。
      expect(list[2].baseUrl, 'http://c:3');
    });

    test('删除默认项后自动把剩下第一条补为默认', () async {
      final DownloaderRepository r = repo();
      await r.upsert(const DownloaderConfig(id: 'd1', name: 'A', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:1'));
      await r.upsert(const DownloaderConfig(id: 'd2', name: 'B', kind: DownloaderKind.qbittorrent, baseUrl: 'http://b:2'));

      await r.remove('d1');

      final List<DownloaderConfig> list = r.loadAll();
      expect(list, hasLength(1));
      expect(list.single.id, 'd2');
      expect(list.single.isDefault, isTrue);
    });

    test('历史数据里出现多个默认时读盘只保留第一个', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ptp.downloaders.index': jsonEncode(<String, dynamic>{
          'version': 1,
          'downloaders': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'd1', 'name': 'A', 'isDefault': true},
            <String, dynamic>{'id': 'd2', 'name': 'B', 'isDefault': true},
          ],
        }),
      });
      final DownloaderRepository r = DownloaderRepository(
        prefs: PrefsStore(await SharedPreferences.getInstance()),
        secure: SecureStore(),
      );

      await r.saveAll(r.loadAll());

      final Map<String, dynamic>? index = r.prefs.getJson(PrefKeys.downloaderIndex);
      final List<dynamic> records = index!['downloaders'] as List<dynamic>;
      expect((records[0] as Map)['isDefault'], isTrue);
      expect((records[1] as Map)['isDefault'], isFalse);
    });
  });

  group('任务筛选与排序', () {
    final List<DownloaderTask> tasks = <DownloaderTask>[
      DownloaderTask(
        hash: 'h1',
        name: 'B 任务',
        sizeBytes: 200,
        state: TaskState.downloading,
        downloadSpeed: 10,
        etaSeconds: 100,
        tracker: 'tracker.a.com',
        tags: const <String>['pt'],
        addedAt: DateTime(2026, 1, 3),
      ),
      DownloaderTask(
        hash: 'h2',
        name: 'A 任务',
        sizeBytes: 100,
        state: TaskState.seeding,
        downloadSpeed: 0,
        etaSeconds: -1,
        tracker: 'tracker.b.com',
        addedAt: DateTime(2026, 1, 1),
      ),
      DownloaderTask(
        hash: 'h3',
        name: 'C 任务',
        sizeBytes: 300,
        state: TaskState.paused,
        downloadSpeed: 0,
        etaSeconds: 50,
        tracker: 'tracker.a.com',
        addedAt: DateTime(2026, 1, 2),
      ),
    ];

    test('默认不筛选，按加入时间倒序（新在前）', () {
      const TaskQuery query = TaskQuery();
      expect(query.isEmptyFilter, isTrue);
      expect(
        query.apply(tasks).map((DownloaderTask t) => t.hash),
        <String>['h1', 'h3', 'h2'],
      );
    });

    test('状态筛选可多选，服务器筛选精确匹配', () {
      final TaskQuery byState = const TaskQuery().copyWith(statuses: <TaskState>{TaskState.paused});
      expect(byState.apply(tasks).map((DownloaderTask t) => t.hash), <String>['h3']);

      final TaskQuery byServer =
          const TaskQuery().copyWith(servers: <String>{'tracker.a.com'});
      expect(byServer.apply(tasks).map((DownloaderTask t) => t.hash), <String>['h1', 'h3']);

      final TaskQuery both = byServer.copyWith(statuses: <TaskState>{TaskState.downloading});
      expect(both.apply(tasks).map((DownloaderTask t) => t.hash), <String>['h1']);
      expect(both.isEmptyFilter, isFalse);
    });

    test('排序字段与正倒序生效，且同键时结果稳定', () {
      final TaskQuery bySize = const TaskQuery().copyWith(sort: TaskSort.size, descending: false);
      expect(bySize.apply(tasks).map((DownloaderTask t) => t.hash), <String>['h2', 'h1', 'h3']);

      final TaskQuery byName = const TaskQuery().copyWith(sort: TaskSort.name, descending: false);
      expect(byName.apply(tasks).map((DownloaderTask t) => t.name), <String>['A 任务', 'B 任务', 'C 任务']);
    });

    test('服务端字段缺失也能解析：标签、服务器、加入时间', () {
      final DownloaderTask task = DownloaderTask.fromJson(<String, dynamic>{
        'hash': 'h9',
        'name': 'X',
        'tags': 'pt, 官种',
        'tracker': 'https://tracker.example.com/announce',
        'addedOn': 1767225600,
      });
      expect(task.tags, <String>['pt', '官种']);
      expect(task.serverLabel, 'tracker.example.com');
      expect(task.addedAt, isNotNull);

      final DownloaderTask bare = DownloaderTask.fromJson(<String, dynamic>{'hash': 'h10'});
      expect(bare.tags, isEmpty);
      expect(bare.serverLabel, '未标注');
      expect(bare.addedAt, isNull);
    });
  });

  group('任务操作接口', () {
    late _RecordingAdapter adapter;
    late DownloaderApi api;

    setUp(() {
      adapter = _RecordingAdapter(<dynamic>[]);
      final EndpointResolver resolver = EndpointResolver(
        probe: (Uri candidate, Duration timeout) async => true,
        profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
      );
      final ApiClient client = ApiClient(resolver: resolver);
      client.raw.httpClientAdapter = adapter;
      api = DownloaderApi(client: client);
    });

    test('分类 / 标签 / 路径下发路径与请求体正确', () async {
      await api.setCategory('d1', <String>['h1', 'h2'], 'pt');
      await api.setTags('d1', <String>['h1'], <String>['官种'], mode: 'add');
      await api.setTags('d1', <String>['h1'], <String>['官种'], mode: 'remove');
      await api.setLocation('d1', <String>['h1'], '/downloads/PT');

      expect(
        adapter.requests.map((RequestOptions r) => '${r.method} ${r.path}').toList(),
        <String>[
          'POST /api/v1/downloaders/d1/tasks/category',
          'POST /api/v1/downloaders/d1/tasks/tags',
          'POST /api/v1/downloaders/d1/tasks/tags',
          'POST /api/v1/downloaders/d1/tasks/location',
        ],
      );

      final Map<String, dynamic> category = adapter.requests[0].data as Map<String, dynamic>;
      expect(category['hashes'], <String>['h1', 'h2']);
      expect(category['category'], 'pt');

      final Map<String, dynamic> tags = adapter.requests[1].data as Map<String, dynamic>;
      expect(tags['tags'], <String>['官种']);
      expect(tags['mode'], 'add');
      expect((adapter.requests[2].data as Map<String, dynamic>)['mode'], 'remove');

      final Map<String, dynamic> location = adapter.requests[3].data as Map<String, dynamic>;
      expect(location['savePath'], '/downloads/PT');
    });

    test('可选值接口解析 categories / tags / paths，缺字段按空处理', () async {
      adapter.payload = <String, dynamic>{
        'categories': <String>['pt', 'movie'],
        'tags': <String>['官种'],
        'paths': <String>['/downloads/PT'],
      };

      final DownloaderTaskOption option = await api.fetchTaskOptions('d1');
      expect(adapter.requests.single.path, '/api/v1/downloaders/d1/task-options');
      expect(option.categories, <String>['pt', 'movie']);
      expect(option.tags, <String>['官种']);
      expect(option.paths, <String>['/downloads/PT']);

      adapter.payload = <String, dynamic>{};
      final DownloaderTaskOption empty = await api.fetchTaskOptions('d1');
      expect(empty.categories, isEmpty);
      expect(empty.tags, isEmpty);
      expect(empty.paths, isEmpty);
    });
  });

  group('界面', () {
    Future<ProviderContainer> container({
      required List<DownloaderConfig> downloaders,
      Object? tasksPayload,
    }) async {
      final DownloaderRepository repository =
          DownloaderRepository(prefs: prefs, secure: SecureStore());
      for (final DownloaderConfig config in downloaders) {
        await repository.upsert(config);
      }
      final _RecordingAdapter adapter = _RecordingAdapter(tasksPayload ?? <dynamic>[]);
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
          downloaderApiProvider.overrideWith((Ref ref) {
            final EndpointResolver resolver = EndpointResolver(
              probe: (Uri candidate, Duration timeout) async => true,
              profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
            );
            final ApiClient client = ApiClient(resolver: resolver);
            client.raw.httpClientAdapter = adapter;
            return DownloaderApi(client: client);
          }),
          endpointProfileProvider.overrideWith(() => _ConfiguredEndpoint()),
        ],
      );
      return c;
    }

    Future<void> pumpPage(WidgetTester tester, ProviderContainer c, String initial) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final GoRouter router = GoRouter(
        initialLocation: initial,
        routes: <RouteBase>[
          GoRoute(
            path: AppRoutes.downloaders,
            builder: (BuildContext context, GoRouterState state) => const DownloadersPage(),
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.downloaderAdd,
                builder: (BuildContext context, GoRouterState state) => const _EditProbePage(),
              ),
              GoRoute(
                path: AppRoutes.downloaderDetail,
                builder: (BuildContext context, GoRouterState state) => DownloaderDetailPage(
                  downloaderId: state.uri.queryParameters['downloaderId'] ?? '',
                ),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('左滑露出「编辑 / 删除 / 默认」，点点「默认」即设为默认', (WidgetTester tester) async {
      final ProviderContainer c = await container(
        downloaders: <DownloaderConfig>[
          const DownloaderConfig(id: 'd1', name: '主力 qB', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:8080'),
          const DownloaderConfig(id: 'd2', name: '备用 tr', kind: DownloaderKind.transmission, baseUrl: 'http://b:9091'),
        ],
      );
      addTearDown(c.dispose);
      await pumpPage(tester, c, AppRoutes.downloaders);

      // 动作按钮始终在树里，只有把卡片滑开才露出来——用卡片是否被推开来判定。
      // （负向 finder 断言在这里不成立：按钮被卡片盖住，但仍在 widget 树中。）
      final double before = tester.getTopLeft(find.text('备用 tr')).dx;

      // 第一条（d1）自动成为默认，因此滑 d2 才能验证「设为默认」的互斥切换。
      await tester.drag(find.text('备用 tr'), const Offset(-260, 0));
      await tester.pumpAndSettle();

      final double after = tester.getTopLeft(find.text('备用 tr')).dx;
      expect(after, lessThan(before - 100), reason: '左滑后卡片应被推开，露出背后的动作按钮');

      // 两张卡片各有一套动作按钮，所以同名标签出现两次。
      expect(find.text('编辑'), findsNWidgets(2));
      expect(find.text('删除'), findsNWidgets(2));
      expect(find.text('默认'), findsWidgets);
      // 「默认」动作：非默认项用空心星，默认项用实心星（顶部徽标也是实心星）。
      expect(find.byIcon(Icons.star_border), findsOneWidget);

      await tester.tap(find.byIcon(Icons.star_border));
      await tester.pumpAndSettle();

      final List<DownloaderConfig> list = c.read(downloaderListProvider).valueOrNull!;
      expect(list.firstWhere((DownloaderConfig d) => d.id == 'd2').isDefault, isTrue);
      expect(list.firstWhere((DownloaderConfig d) => d.id == 'd1').isDefault, isFalse);
    });

    testWidgets('左滑点「编辑」进入编辑页，点「删除」先弹确认', (WidgetTester tester) async {
      final ProviderContainer c = await container(
        downloaders: <DownloaderConfig>[
          const DownloaderConfig(id: 'd1', name: '主力 qB', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:8080'),
        ],
      );
      addTearDown(c.dispose);
      await pumpPage(tester, c, AppRoutes.downloaders);

      await tester.drag(find.text('主力 qB'), const Offset(-260, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除下载器'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.read(downloaderListProvider).valueOrNull, hasLength(1));

      await tester.drag(find.text('主力 qB'), const Offset(-260, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(_EditProbePage), findsOneWidget);
    });

    testWidgets('任务页不展示连接信息与操作框，提供筛选 / 排序 / 批量入口', (WidgetTester tester) async {
      final ProviderContainer c = await container(
        downloaders: <DownloaderConfig>[
          const DownloaderConfig(id: 'd1', name: '主力 qB', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:8080'),
        ],
        tasksPayload: <dynamic>[
          <String, dynamic>{
            'hash': 'h1',
            'name': '甲',
            'size': 100,
            'completed': 50,
            'state': 'downloading',
            'tracker': 'tracker.a.com',
          },
          <String, dynamic>{
            'hash': 'h2',
            'name': '乙',
            'size': 200,
            'completed': 200,
            'state': 'paused',
            'tracker': 'tracker.b.com',
          },
        ],
      );
      addTearDown(c.dispose);
      await pumpPage(tester, c, AppRoutes.downloaders);
      await tester.tap(find.text('主力 qB'));
      await tester.pumpAndSettle();

      // 不再出现连接信息与连接测试操作框。
      expect(find.text('连接信息'), findsNothing);
      expect(find.text('测试连接'), findsNothing);
      expect(find.text('编辑配置'), findsNothing);
      expect(find.textContaining('http://a:8080'), findsNothing);

      // 任务本身可见，筛选入口在右上角（三横线），正文只有条数与排序摘要。
      expect(find.text('甲'), findsOneWidget);
      expect(find.text('乙'), findsOneWidget);
      expect(find.byIcon(Icons.filter_list), findsOneWidget);
      expect(find.text('共 2 条任务'), findsOneWidget);
      expect(find.textContaining('排序 加入时间'), findsOneWidget);

      // 打开筛选面板：状态 / 分类 / 标签 / 路径 / 服务器 都在，
      // 没有取值的维度不虚构候选，直接写明原因。
      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      expect(find.text('筛选'), findsOneWidget);
      expect(find.text('任务里还没有分类'), findsOneWidget);
      expect(find.text('任务里还没有标签'), findsOneWidget);
      expect(find.text('任务里还没有保存路径'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, '全部服务器'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'tracker.a.com (1)'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, '已暂停 (1)'), findsOneWidget);

      // 状态筛选：只看已暂停 → 只剩「乙」。
      await tester.tap(find.widgetWithText(FilterChip, '已暂停 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('甲'), findsNothing);
      expect(find.text('乙'), findsOneWidget);
      expect(find.textContaining('筛选出 1 条'), findsOneWidget);
    });

    testWidgets('多选后可批量下发暂停', (WidgetTester tester) async {
      final ProviderContainer c = await container(
        downloaders: <DownloaderConfig>[
          const DownloaderConfig(id: 'd1', name: '主力 qB', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:8080'),
        ],
        tasksPayload: <dynamic>[
          <String, dynamic>{'hash': 'h1', 'name': '甲', 'size': 100, 'completed': 50, 'state': 'downloading'},
          <String, dynamic>{'hash': 'h2', 'name': '乙', 'size': 200, 'completed': 100, 'state': 'downloading'},
        ],
      );
      addTearDown(c.dispose);
      await pumpPage(tester, c, AppRoutes.downloaders);
      await tester.tap(find.text('主力 qB'));
      await tester.pumpAndSettle();

      // 多选入口改为「长按任务卡片」（右上角不再放多选按钮）。
      await tester.longPress(find.text('甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 条'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '暂停'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已批量下发'), findsOneWidget);
    });
  });
}

/// 进入编辑页的探针（避免在测试里构建真实的编辑表单）。
class _EditProbePage extends StatelessWidget {
  const _EditProbePage();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('编辑页'));
}

/// 已配置好 NAS 地址的链路档案（任务页与列表页据此不再显示未配对提示）。
class _ConfiguredEndpoint extends EndpointProfileNotifier {
  @override
  EndpointProfile build() => EndpointProfile(
        lanBaseUrl: Uri.parse('http://192.168.1.10:8000'),
        mode: LinkMode.auto,
      );
}