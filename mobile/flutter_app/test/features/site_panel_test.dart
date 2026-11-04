// 站点数据面板测试（需求 4）：
// - 站点的刷新状态四态口径与新增指标字段解析；
// - 单站 / 批量刷新的接口路径与请求体；
// - 界面级：打码、扩展展示、四态筛选、刷新与「更多（PT 历程）」入口。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/models/status_models.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/router/app_routes.dart';
import 'package:pt_pocket/core/services/status_api.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:pt_pocket/core/storage/site_repository.dart';
import 'package:pt_pocket/features/settings/status_providers.dart';
import 'package:pt_pocket/features/sites/sites_page.dart';
import 'package:shared_preferences/shared_preferences.dart';


class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.payload);

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

ApiClient _clientWith(HttpClientAdapter adapter) {
  final EndpointResolver resolver = EndpointResolver(
    probe: (Uri candidate, Duration timeout) async => true,
    profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
  );
  final ApiClient client = ApiClient(resolver: resolver);
  client.raw.httpClientAdapter = adapter;
  return client;
}

void main() {
  late PrefsStore prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    prefs = PrefsStore(await SharedPreferences.getInstance());
  });

  group('刷新状态四态口径', () {
    test('后端各写法都能归到四态，未知值落到「未检测」', () {
      expect(SiteRefreshState.fromName('refreshed'), SiteRefreshState.refreshed);
      expect(SiteRefreshState.fromName('ok'), SiteRefreshState.refreshed);
      expect(SiteRefreshState.fromName('stale'), SiteRefreshState.stale);
      expect(SiteRefreshState.fromName('never'), SiteRefreshState.stale);
      expect(SiteRefreshState.fromName('failed'), SiteRefreshState.failed);
      expect(SiteRefreshState.fromName('error'), SiteRefreshState.failed);
      expect(SiteRefreshState.fromName('notLoggedIn'), SiteRefreshState.notLoggedIn);
      expect(SiteRefreshState.fromName('unauthorized'), SiteRefreshState.notLoggedIn);
      expect(SiteRefreshState.fromName(''), SiteRefreshState.unknown);
      expect(SiteRefreshState.fromName(null), SiteRefreshState.unknown);
    });

    test('筛选只暴露四态，不含「未检测」', () {
      expect(SiteRefreshState.filterable, hasLength(4));
      expect(SiteRefreshState.filterable, isNot(contains(SiteRefreshState.unknown)));
    });
  });

  group('站点指标解析', () {
    test('新增指标（时魔 / 连接数 / HR / 邮件 / 邀请 / 图标）都能读出来', () {
      final SiteStats stats = SiteStats.fromJson(<String, dynamic>{
        'siteId': 's1',
        'siteName': '站点一',
        'iconUrl': 'https://example.com/icon.png',
        'uploaded': 1073741824,
        'downloaded': 536870912,
        'bonus': 12345,
        'hourlyBonus': 12.5,
        'seeding': 30,
        'leeching': 2,
        'connections': 42,
        'hrCount': 3,
        'unreadMessages': 2,
        'invites': 1,
        'signedInToday': true,
        'consecutiveSignInDays': 12,
        'refreshState': 'refreshed',
        'refreshedAt': '2026-11-04T08:00:00Z',
      });

      expect(stats.iconUrl, 'https://example.com/icon.png');
      expect(stats.uploadedBytes, 1073741824);
      expect(stats.downloadedBytes, 536870912);
      expect(stats.ratioLabel, '2.00');
      expect(stats.seedingCount, 30);
      expect(stats.hourlyBonus, 12.5);
      expect(stats.hourlyBonusLabel, '12.50/h');
      expect(stats.connections, 42);
      expect(stats.hrCount, 3);
      expect(stats.hrLabel, '3 项');
      expect(stats.unreadMessages, 2);
      expect(stats.invites, 1);
      expect(stats.signInLabel, '已签 · 连续 12 天');
      expect(stats.refreshState, SiteRefreshState.refreshed);
      expect(stats.refreshedAt, isNotNull);
    });

    test('字段缺失时不填 0 冒充：HR / 时魔 / 图标都有「未提供」表达', () {
      final SiteStats stats = SiteStats.fromJson(<String, dynamic>{
        'siteId': 's2',
        'siteName': '站点二',
        'refreshState': 'failed',
        'refreshMessage': '登录态失效，请重新导入 Cookie',
      });

      expect(stats.iconUrl, isEmpty);
      expect(stats.hourlyBonusLabel, '—');
      expect(stats.hrLabel, '无');
      expect(stats.signInLabel, '未签');
      expect(stats.iconLetter, '站');
      expect(stats.refreshState, SiteRefreshState.failed);
      expect(stats.refreshMessage, contains('登录态失效'));
      expect(stats.ratioLabel, '—');
    });

    test('站点名首字用于图标回退，英文首字母大写', () {
      expect(const SiteStats(siteId: 's', siteName: '馒头').iconLetter, '馒');
      expect(const SiteStats(siteId: 's', siteName: 'hhanclub').iconLetter, 'H');
      expect(const SiteStats(siteId: 's', siteName: '  ').iconLetter, '?');
    });
  });

  group('刷新接口', () {
    test('单站与批量刷新的路径和请求体正确', () async {
      final _RoutingAdapter adapter = _RoutingAdapter(<String, dynamic>{'ok': true});
      final SiteStatsApi api = SiteStatsApi(client: _clientWith(adapter));

      await api.refreshSite('s1');
      await api.refreshAll(siteIds: <String>['s1', 's2']);

      expect(
        adapter.requests.map((RequestOptions r) => '${r.method} ${r.path}').toList(),
        <String>['POST /api/v1/sites/s1/refresh', 'POST /api/v1/sites/refresh'],
      );
      expect(
        (adapter.requests[1].data as Map<String, dynamic>)['siteIds'],
        <String>['s1', 's2'],
      );
    });
  });

  group('界面', () {
    const Map<String, dynamic> profilePayload = <String, dynamic>{
      'sites': <Map<String, dynamic>>[
        <String, dynamic>{
          'siteId': 's1',
          'siteName': '甲站',
          'uploaded': 1073741824,
          'downloaded': 536870912,
          'seeding': 30,
          'hourlyBonus': 12.5,
          'connections': 42,
          'hrCount': 3,
          'unreadMessages': 2,
          'invites': 1,
          'signedInToday': true,
          'consecutiveSignInDays': 12,
          'refreshState': 'refreshed',
        },
        <String, dynamic>{
          'siteId': 's2',
          'siteName': '乙站',
          'refreshState': 'failed',
          'refreshMessage': '登录态失效，请重新导入 Cookie',
        },
      ],
    };

    /// 返回容器与「命令型」请求的记录适配器（刷新接口用它取证）。
    Future<(ProviderContainer, _RoutingAdapter)> container() async {
      final SiteRepository repository =
          SiteRepository(prefs: prefs, secure: SecureStore());
      await repository.upsert(const PtSite(id: 's1', name: '甲站', baseUrl: 'https://a.example'));
      await repository.upsert(const PtSite(id: 's2', name: '乙站', baseUrl: 'https://b.example'));

      final _RoutingAdapter profileAdapter = _RoutingAdapter(profilePayload);
      final _RoutingAdapter commandAdapter = _RoutingAdapter(<String, dynamic>{'ok': true});
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
          profileApiProvider.overrideWith((Ref ref) => ProfileApi(client: _clientWith(profileAdapter))),
          siteStatsApiProvider
              .overrideWith((Ref ref) => SiteStatsApi(client: _clientWith(commandAdapter))),
        ],
      );
      return (c, commandAdapter);
    }

    Future<void> pumpPage(WidgetTester tester, ProviderContainer c) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final GoRouter router = GoRouter(
        initialLocation: AppRoutes.sites,
        routes: <RouteBase>[
          GoRoute(
            path: AppRoutes.sites,
            builder: (BuildContext context, GoRouterState state) => const SitesPage(),
          ),
          GoRoute(
            path: AppRoutes.settingsPtDataPath,
            builder: (BuildContext context, GoRouterState state) =>
                const Scaffold(body: Text('PT 历程页')),
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

    testWidgets('卡片展示核心指标，打码后数值被遮蔽', (WidgetTester tester) async {
      final (ProviderContainer c, _RoutingAdapter _) = await container();
      addTearDown(c.dispose);
      await pumpPage(tester, c);

      // 核心指标：上传 / 下载 / 分享率 / 做种 / 时魔 / 签到。
      expect(find.text('上传'), findsWidgets);
      expect(find.text('分享率'), findsWidgets);
      expect(find.text('做种'), findsWidgets);
      expect(find.text('时魔'), findsWidgets);
      expect(find.text('12.50/h'), findsOneWidget);
      expect(find.text('2.00'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pumpAndSettle();

      // 打码后真实数值不再出现在界面上。
      expect(find.text('•••'), findsWidgets);
      expect(find.text('12.50/h'), findsNothing);
      expect(find.text('2.00'), findsNothing);

      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pumpAndSettle();
      expect(find.text('12.50/h'), findsOneWidget);
    });

    testWidgets('扩展展示补齐连接数 / HR / 邮件 / 邀请', (WidgetTester tester) async {
      final (ProviderContainer c, _RoutingAdapter _) = await container();
      addTearDown(c.dispose);
      await pumpPage(tester, c);

      expect(find.text('连接数'), findsNothing);
      await tester.tap(find.byIcon(Icons.grid_view));
      await tester.pumpAndSettle();

      expect(find.text('连接数'), findsWidgets);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('HR 情况'), findsWidgets);
      expect(find.text('3 项'), findsOneWidget);
      expect(find.text('邮件数'), findsWidgets);
      expect(find.text('邀请数'), findsWidgets);
    });

    testWidgets('四态筛选：只看「失败」只剩对应站点，切回全部恢复', (WidgetTester tester) async {
      final (ProviderContainer c, _RoutingAdapter _) = await container();
      addTearDown(c.dispose);
      await pumpPage(tester, c);

      expect(find.text('甲站'), findsOneWidget);
      expect(find.text('乙站'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, '失败'));
      await tester.pumpAndSettle();
      expect(find.text('甲站'), findsNothing);
      expect(find.text('乙站'), findsOneWidget);
      expect(find.textContaining('登录态失效'), findsOneWidget);

      // 状态胶囊是多选的：先回到「全部」再切到「已刷新」，否则两个状态同时生效。
      await tester.tap(find.widgetWithText(FilterChip, '全部'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilterChip, '已刷新'));
      await tester.pumpAndSettle();
      expect(find.text('甲站'), findsOneWidget);
      expect(find.text('乙站'), findsNothing);

      await tester.tap(find.widgetWithText(FilterChip, '全部'));
      await tester.pumpAndSettle();
      expect(find.text('甲站'), findsOneWidget);
      expect(find.text('乙站'), findsOneWidget);
    });

    testWidgets('顶部刷新对每个站点数据下发批量刷新', (WidgetTester tester) async {
      final (ProviderContainer c, _RoutingAdapter commandAdapter) = await container();
      addTearDown(c.dispose);
      await pumpPage(tester, c);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();

      expect(commandAdapter.requests, hasLength(1));
      expect(commandAdapter.requests.single.path, '/api/v1/sites/refresh');
      expect(
        (commandAdapter.requests.single.data as Map<String, dynamic>)['siteIds'],
        <String>['s1', 's2'],
        reason: '刷新的范围应是全部启用站点',
      );
      expect(find.textContaining('已下发站点数据刷新'), findsOneWidget);
    });

    testWidgets('「更多」入口可进 PT 历程', (WidgetTester tester) async {
      final (ProviderContainer c, _RoutingAdapter _) = await container();
      addTearDown(c.dispose);
      await pumpPage(tester, c);

      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(find.text('PT 历程与数据统计'), findsOneWidget);

      await tester.tap(find.text('PT 历程与数据统计'));
      await tester.pumpAndSettle();
      expect(find.text('PT 历程页'), findsOneWidget);
    });
  });
}