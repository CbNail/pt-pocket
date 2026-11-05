// 本轮「站点」问题修复的界面与数据链路测试：
// - PTD 备份导入：已有站点（本机无凭据）应补齐凭据，已有凭据的站点不被覆盖；
// - 凭据标记自愈：安全存储里有凭据但标记为未配置时，reconcileCredentials 会修正；
// - 站点卡片：点击进站点资源页，右上角菜单含「编辑站点」，左滑露出「编辑」「删除」；
// - 顶部工具条：打码与详细 / 概述切换都会落盘，重进页面保持；
// - 站点编辑页不再出现「导入与登录」模块（登录入口并入凭据区）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/router/app_routes.dart';
import 'package:pt_pocket/core/services/status_api.dart';
import 'package:pt_pocket/core/storage/app_keys.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:pt_pocket/core/storage/site_repository.dart';
import 'package:pt_pocket/features/settings/status_providers.dart';
import 'package:pt_pocket/features/sites/ptd_import_page.dart';
import 'package:pt_pocket/features/sites/site_detail_page.dart';
import 'package:pt_pocket/features/sites/site_providers.dart';
import 'package:pt_pocket/features/sites/site_resources_page.dart';
import 'package:pt_pocket/features/sites/sites_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录型适配器（NAS 回退路径用），不产生真实网络访问。
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

ApiClient _clientWith(HttpClientAdapter adapter) {
  final EndpointResolver resolver = EndpointResolver(
    probe: (Uri candidate, Duration timeout) async => true,
    profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
  );
  final ApiClient client = ApiClient(resolver: resolver);
  client.raw.httpClientAdapter = adapter;
  return client;
}

class _ConfiguredEndpoint extends EndpointProfileNotifier {
  @override
  EndpointProfile build() => EndpointProfile(
        lanBaseUrl: Uri.parse('http://192.168.1.10:8000'),
        mode: LinkMode.auto,
      );
}

const Map<String, dynamic> _profilePayload = <String, dynamic>{
  'sites': <Map<String, dynamic>>[
    <String, dynamic>{
      'siteId': 's1',
      'siteName': '甲站',
      'username': 'CBNail',
      'userClass': 'Power User',
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
  ],
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('PTD 备份导入的凭据处理', () {
    Future<ProviderContainer> containerWithSite({
      required bool credentialConfigured,
      String? credentialCookie,
    }) async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(prefs), secure: SecureStore());
      await repository.upsert(
        const PtSite(id: 'existing', name: '馒头', baseUrl: 'https://kp.m-team.cc'),
      );
      if (!credentialConfigured) {
        // 站点存在（可访问、已连通），但本机没有凭据 —— 正是实机反馈的场景。
        final List<PtSite> sites = repository.loadAll();
        await repository.saveAll(
          sites.map((PtSite s) => s.copyWith(credentialConfigured: false)).toList(),
        );
      }
      if (credentialCookie != null) {
        await repository.saveCredential('existing', <String, dynamic>{
          'type': 'cookie',
          'cookie': credentialCookie,
        });
      }
      return ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
    }

    Future<void> pumpImportPage(WidgetTester tester, ProviderContainer c) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PtdImportPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> importJson(WidgetTester tester, String json) async {
      await tester.enterText(find.byType(TextField).first, json);
      await tester.tap(find.text('解析备份'));
      await tester.pumpAndSettle();
      final Finder importButton = find.text('导入全部可导入条目');
      await tester.ensureVisible(importButton);
      await tester.pumpAndSettle();
      await tester.tap(importButton);
      await tester.pumpAndSettle();
    }

    testWidgets('已有站点（本机缺凭据）导入后补齐凭据，并标记为已配置', (WidgetTester tester) async {
      final ProviderContainer c =
          await containerWithSite(credentialConfigured: false);
      addTearDown(c.dispose);
      await pumpImportPage(tester, c);

      await importJson(
        tester,
        jsonEncode(<String, dynamic>{
          'sites': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '馒头',
              'baseUrl': 'https://kp.m-team.cc',
              'cookie': 'c_secure_uid=abc; c_secure_pass=def',
            },
          ],
        }),
      );

      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(await SharedPreferences.getInstance()), secure: SecureStore());
      final PtSite site = repository.loadAll().single;
      expect(site.credentialConfigured, isTrue, reason: '凭据已写入本机，状态标记必须同步');
      final Map<String, dynamic>? credential = await repository.readCredential(site.id);
      expect(credential?['cookie'], contains('c_secure_pass'));
      expect(find.textContaining('补齐凭据'), findsWidgets, reason: '提示要说清是补齐而不是新增');
    });

    testWidgets('已有站点（本机已有凭据）不会被备份覆盖', (WidgetTester tester) async {
      final ProviderContainer c = await containerWithSite(
        credentialConfigured: false,
        credentialCookie: 'c_secure_pass=LOCALONLY',
      );
      addTearDown(c.dispose);
      await pumpImportPage(tester, c);

      await importJson(
        tester,
        jsonEncode(<String, dynamic>{
          'sites': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '馒头',
              'baseUrl': 'https://kp.m-team.cc',
              'cookie': 'c_secure_pass=FROMPTD',
            },
          ],
        }),
      );

      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(await SharedPreferences.getInstance()), secure: SecureStore());
      final Map<String, dynamic>? credential = await repository.readCredential('existing');
      expect(credential?['cookie'], 'c_secure_pass=LOCALONLY', reason: '本机凭据更可能更新，不覆盖');
      expect(find.textContaining('保留本机凭据'), findsWidgets);
    });

    testWidgets('新站点按备份里的凭据类型写入认证方式（API Key）', (WidgetTester tester) async {
      final ProviderContainer c =
          await containerWithSite(credentialConfigured: false);
      addTearDown(c.dispose);
      await pumpImportPage(tester, c);

      await importJson(
        tester,
        jsonEncode(<String, dynamic>{
          'sites': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '某站',
              'baseUrl': 'https://new.example',
              'apiKey': 'KEY-123',
            },
          ],
        }),
      );

      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(await SharedPreferences.getInstance()), secure: SecureStore());
      final PtSite created = repository
          .loadAll()
          .firstWhere((PtSite s) => s.host == 'new.example');
      expect(created.authType, SiteAuthType.apiKey, reason: '认证方式要与实际写入的凭据一致');
      expect(created.credentialConfigured, isTrue);
      expect((await repository.readCredential(created.id))?['apiKey'], 'KEY-123');
    });
  });

  group('凭据标记自愈', () {
    test('安全存储里有凭据、标记却是未配置时会被修正', () async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(prefs), secure: SecureStore());
      await repository.upsert(
        const PtSite(
          id: 's1',
          name: '甲站',
          baseUrl: 'https://a.example',
          credentialConfigured: false,
        ),
      );
      // 模拟旧版本 / 导入流程直接写凭据但没同步标记的情况。
      await repository.saveCredential('s1', <String, dynamic>{'type': 'cookie', 'cookie': 'a=1'});

      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(c.dispose);
      final int fixed = await c.read(siteListProvider.notifier).reconcileCredentials();
      expect(fixed, 1);
      final PtSite site = c.read(siteListProvider).valueOrNull!.single;
      expect(site.credentialConfigured, isTrue);
    });
  });

  group('站点列表交互', () {
    Future<ProviderContainer> container({bool maskPersisted = false}) async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (maskPersisted) {
        await PrefsStore(prefs).setBool(PrefKeys.sitesMasked, true);
      }
      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(prefs), secure: SecureStore());
      await repository.upsert(
        const PtSite(id: 's1', name: '甲站', baseUrl: 'https://a.example', credentialConfigured: true),
      );
      await repository.saveCredential('s1', <String, dynamic>{'type': 'cookie', 'cookie': 'a=1'});

      final _RecordingAdapter adapter = _RecordingAdapter(_profilePayload);
      return ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
          profileApiProvider.overrideWith((Ref ref) => ProfileApi(client: _clientWith(adapter))),
          endpointProfileProvider.overrideWith(_ConfiguredEndpoint.new),
          // 站点资源页的数据源：用固定结果替代真实站点请求。
          siteResourcesProvider.overrideWith(
            (Ref ref, SiteResourceQuery query) async => SearchPageResult(
              items: <SearchResultItem>[
                const SearchResultItem(
                  id: '12345',
                  title: '示例资源 2160p',
                  siteId: 's1',
                  siteName: '甲站',
                  sizeBytes: 1073741824,
                  seeders: 12,
                  leechers: 3,
                ),
              ],
              page: 1,
              pageSize: 50,
              hasMore: false,
            ),
          ),
        ],
      );
    }

    Future<void> pumpSites(WidgetTester tester, ProviderContainer c) async {
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
            path: AppRoutes.siteResourcesPath(':unused').split('?').first,
            builder: (BuildContext context, GoRouterState state) =>
                SiteResourcesPage(siteId: state.uri.queryParameters['siteId'] ?? 's1'),
          ),
          GoRoute(
            path: AppRoutes.siteDetailPath(':unused').split('?').first,
            builder: (BuildContext context, GoRouterState state) =>
                SiteDetailPage(siteId: state.uri.queryParameters['siteId'] ?? 's1'),
          ),
          GoRoute(
            path: AppRoutes.torrentDetailPath,
            builder: (BuildContext context, GoRouterState state) => const Scaffold(
              body: Text('资源详情页'),
            ),
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

    testWidgets('点击卡片进入站点资源页（含从站点拉取的资源）', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpSites(tester, c);

      await tester.tap(find.text('甲站'));
      await tester.pumpAndSettle();

      expect(find.text('站点概况'), findsOneWidget);
      expect(find.text('账号数据'), findsOneWidget);
      expect(find.text('站点资源'), findsOneWidget);
      expect(find.text('示例资源 2160p'), findsOneWidget);
      expect(find.text('Power User'), findsWidgets, reason: '账号数据来自站点用户页');
    });

    testWidgets('卡片右上角菜单含「编辑站点」并可进入编辑页', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpSites(tester, c);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('编辑站点'), findsOneWidget);
      expect(find.text('删除站点'), findsOneWidget);

      await tester.tap(find.text('编辑站点'));
      await tester.pumpAndSettle();
      expect(find.text('编辑 · 甲站'), findsOneWidget);
    });

    testWidgets('左滑卡片露出「编辑」「删除」', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpSites(tester, c);

      final double before = tester.getTopLeft(find.text('甲站')).dx;
      await tester.drag(find.text('甲站'), const Offset(-260, 0));
      await tester.pumpAndSettle();
      final double after = tester.getTopLeft(find.text('甲站')).dx;
      expect(after, lessThan(before - 100), reason: '左滑后卡片被推开，才会露出背后的动作');

      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);

      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('编辑 · 甲站'), findsOneWidget);
    });

    testWidgets('详细 / 概述切换生效并落盘', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpSites(tester, c);

      // 默认概述：不展示「连接数」这类详细指标。
      expect(find.text('连接数'), findsNothing);
      await tester.tap(find.byIcon(Icons.grid_view));
      await tester.pumpAndSettle();
      expect(find.text('连接数'), findsWidgets);
      final PrefsStore prefs = PrefsStore(await SharedPreferences.getInstance());
      expect(prefs.getString(PrefKeys.sitesViewMode), 'detailed');
    });

    testWidgets('打码开关写进偏好，重进页面保持打码', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpSites(tester, c);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pumpAndSettle();
      expect(find.text('•••'), findsWidgets);
      final PrefsStore prefs = PrefsStore(await SharedPreferences.getInstance());
      expect(prefs.getBool(PrefKeys.sitesMasked), isTrue);

      final ProviderContainer reloaded = await container(maskPersisted: true);
      addTearDown(reloaded.dispose);
      await pumpSites(tester, reloaded);
      expect(find.text('•••'), findsWidgets, reason: '重进页面应保持已打码状态');
    });

    testWidgets('站点编辑页已移除「导入与登录」模块，登录入口并入凭据区',
        (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpSites(tester, c);

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑站点'));
      await tester.pumpAndSettle();

      expect(find.text('导入与登录'), findsNothing);
      expect(find.text('参与范围'), findsOneWidget);
      expect(find.text('内置浏览器登录'), findsOneWidget);
    });
  });
}