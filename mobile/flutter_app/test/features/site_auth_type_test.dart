// 站点认证方式（凭据类型）测试：
// - 默认项：按站点架构给推荐认证方式，且「不允许 Cookie 抓取」的站点默认落到 API Key；
// - 可选集合：关闭 Cookie 抓取后不再提供 Cookie 选项，用户仍可自行选择其它类型；
// - 直连门禁：非 Cookie 认证 / 禁止 Cookie 抓取的站点给出按认证方式归因的原因，
//   不再一律报「未保存 Cookie」；
// - 模型：cookieAllowed 落盘并在缺省时按域名策略推断。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pt_pocket/core/adapters/site_adapter_registry.dart';
import 'package:pt_pocket/core/direct/nexusphp_client.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/router/app_routes.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:pt_pocket/core/storage/site_repository.dart';
import 'package:pt_pocket/features/sites/site_add_page.dart';
import 'package:pt_pocket/features/sites/site_detail_page.dart';
import 'package:pt_pocket/features/sites/site_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  group('认证方式默认项', () {
    test('按站点架构给推荐认证方式', () {
      expect(SiteAdapterRegistry.recommendedAuthType(SiteFramework.nexusphp), SiteAuthType.cookie);
      expect(SiteAdapterRegistry.recommendedAuthType(SiteFramework.btitracker), SiteAuthType.cookie);
      expect(SiteAdapterRegistry.recommendedAuthType(SiteFramework.unit3d), SiteAuthType.apiKey);
      expect(SiteAdapterRegistry.recommendedAuthType(SiteFramework.gazelle), SiteAuthType.apiKey);
      expect(SiteAdapterRegistry.recommendedAuthType(SiteFramework.custom), SiteAuthType.cookie);
    });

    test('可选集合按架构过滤，且都包含推荐项', () {
      for (final SiteFramework framework in SiteFramework.values) {
        final List<SiteAuthType> allowed = SiteAdapterRegistry.authTypesFor(framework);
        expect(allowed, isNotEmpty, reason: '${framework.label} 至少要有一个可选项');
        expect(
          allowed.contains(SiteAdapterRegistry.recommendedAuthType(framework)),
          isTrue,
          reason: '${framework.label} 的推荐项必须落在可选集合里',
        );
      }
    });

    test('关闭 Cookie 抓取时默认落到 API Key', () {
      expect(
        SiteAdapterRegistry.defaultAuthTypeFor(SiteFramework.nexusphp, cookieAllowed: false),
        SiteAuthType.apiKey,
      );
      expect(
        SiteAdapterRegistry.defaultAuthTypeFor(SiteFramework.nexusphp, cookieAllowed: true),
        SiteAuthType.cookie,
      );
      expect(
        SiteAdapterRegistry.authTypesFor(SiteFramework.nexusphp),
        contains(SiteAuthType.cookie),
      );
    });

    test('Cookie 抓取策略：M-Team 默认禁止，普通站点允许', () {
      expect(SiteCookiePolicy.allowsCookieByDefault('kp.m-team.cc'), isFalse);
      expect(SiteCookiePolicy.allowsCookieByDefault('api.m-team.io'), isFalse);
      expect(SiteCookiePolicy.allowsCookieByDefault('m-team.cc'), isFalse);
      expect(SiteCookiePolicy.allowsCookieByDefault('audiences.me'), isTrue);
      expect(SiteCookiePolicy.allowsCookieByDefault(''), isTrue);
      expect(SiteCookiePolicy.reason('kp.m-team.cc'), contains('API Key'));
    });

    test('站点模型：cookieAllowed 落盘，缺省按域名推断', () {
      const PtSite site = PtSite(
        id: 's1',
        name: '甲乙',
        baseUrl: 'https://kp.m-team.cc',
        cookieAllowed: false,
      );
      final PtSite restored = PtSite.fromJson(site.toJson());
      expect(restored.cookieAllowed, isFalse);

      // 旧数据没有该字段时按域名策略推断。
      final PtSite legacy = PtSite.fromJson(<String, dynamic>{
        'id': 's2',
        'name': '旧站',
        'baseUrl': 'https://kp.m-team.cc',
      });
      expect(legacy.cookieAllowed, isFalse);
      final PtSite legacyNormal = PtSite.fromJson(<String, dynamic>{
        'id': 's3',
        'name': '旧站2',
        'baseUrl': 'https://audiences.me',
      });
      expect(legacyNormal.cookieAllowed, isTrue);
    });
  });

  group('直连门禁按认证方式归因', () {
    final Uri base = Uri.parse('https://example.com');

    test('API Key 认证：报「认证方式不支持直连」而不是「未保存 Cookie」', () {
      const PtSite site = PtSite(
        id: 's1',
        name: '某 Unit3D 站',
        baseUrl: 'https://example.com',
        framework: SiteFramework.unit3d,
        authType: SiteAuthType.apiKey,
      );
      expect(
        () => NexusPhpClient.requireDirectCookie(site, <String, dynamic>{
          'type': 'apiKey',
          'apiKey': 'KEY',
        }, base),
        throwsA(
          isA<SiteFetchException>()
              .having((SiteFetchException e) => e.kind, 'kind',
                  SiteFetchFailureKind.unsupportedAuth)
              .having((SiteFetchException e) => e.message, 'message', contains('API Key')),
        ),
      );
    });

    test('禁止 Cookie 抓取的站点：报「站点禁止 Cookie 抓取」', () {
      const PtSite site = PtSite(
        id: 's1',
        name: '馒头',
        baseUrl: 'https://kp.m-team.cc',
        cookieAllowed: false,
      );
      expect(
        () => NexusPhpClient.requireDirectCookie(site, <String, dynamic>{
          'type': 'cookie',
          'cookie': 'a=1',
        }, base),
        throwsA(
          isA<SiteFetchException>().having((SiteFetchException e) => e.kind, 'kind',
              SiteFetchFailureKind.cookieForbidden),
        ),
      );
    });

    test('Cookie 认证但未录凭据：仍报「缺少凭据」', () {
      const PtSite site = PtSite(
        id: 's1',
        name: 'audiences',
        baseUrl: 'https://audiences.me',
      );
      expect(
        () => NexusPhpClient.requireDirectCookie(site, null, base),
        throwsA(
          isA<SiteFetchException>().having((SiteFetchException e) => e.kind, 'kind',
              SiteFetchFailureKind.missingCredential),
        ),
      );
    });

    test('Cookie 认证且已录凭据：正常返回 Cookie', () {
      const PtSite site = PtSite(
        id: 's1',
        name: 'audiences',
        baseUrl: 'https://audiences.me',
      );
      final String cookie = NexusPhpClient.requireDirectCookie(
        site,
        <String, dynamic>{'type': 'cookie', 'cookie': 'c_secure_pass=abc'},
        base,
      );
      expect(cookie, 'c_secure_pass=abc');
    });
  });

  group('添加站点：默认项与自定义', () {
    Future<ProviderContainer> container() async => ProviderContainer(
          overrides: <Override>[
            sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
          ],
        );

    Future<void> pumpAdd(WidgetTester tester, ProviderContainer c) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: SiteAddPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('默认架构为 NexusPHP 时推荐 Cookie，并标出「推荐」', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpAdd(tester, c);

      expect(find.text('Cookie（推荐）'), findsWidgets);
      expect(find.textContaining('推荐用 Cookie 维护登录态'), findsOneWidget);
    });

    testWidgets('M-Team 地址：默认禁用 Cookie 抓取、认证方式落到 API Key', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpAdd(tester, c);

      await tester.enterText(find.byType(TextFormField).at(1), 'https://kp.m-team.cc');
      await tester.pumpAndSettle();

      expect(find.textContaining('不允许以登录态（Cookie）抓取页面数据'), findsWidgets);
      expect(find.text('API Key / 存取令牌'), findsOneWidget);
      expect(find.text('UID（可选）'), findsOneWidget);
      expect(find.text('Cookie'), findsNothing, reason: '关闭 Cookie 抓取后不再提供 Cookie 选项');
    });

    testWidgets('Unit3D 架构：默认推荐 API Key', (WidgetTester tester) async {
      final ProviderContainer c = await container();
      addTearDown(c.dispose);
      await pumpAdd(tester, c);

      await tester.tap(find.text('NexusPHP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unit3D').last);
      await tester.pumpAndSettle();

      expect(find.text('API Key（推荐）'), findsWidgets);
    });
  });

  group('编辑站点：可改认证方式', () {
    Future<ProviderContainer> containerWithSite(PtSite site) async {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(prefs), secure: SecureStore());
      await repository.upsert(site);
      return ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
    }

    Future<void> pumpEdit(WidgetTester tester, ProviderContainer c, String siteId) async {
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final GoRouter router = GoRouter(
        initialLocation: AppRoutes.siteDetailPath(siteId),
        routes: <RouteBase>[
          GoRoute(
            path: '/sites',
            builder: (BuildContext context, GoRouterState state) =>
                SiteDetailPage(siteId: state.uri.queryParameters['siteId'] ?? siteId),
            routes: <RouteBase>[
              GoRoute(
                path: 'detail',
                builder: (BuildContext context, GoRouterState state) =>
                    SiteDetailPage(siteId: state.uri.queryParameters['siteId'] ?? siteId),
              ),
              GoRoute(
                path: 'vaultwarden',
                builder: (BuildContext context, GoRouterState state) =>
                    const Scaffold(body: Text('登录页')),
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: MaterialApp.router(routerConfig: router)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('把认证方式从 Cookie 改为 API Key 并落盘', (WidgetTester tester) async {
      const PtSite site = PtSite(
        id: 's1',
        name: 'audiences',
        baseUrl: 'https://audiences.me',
      );
      final ProviderContainer c = await containerWithSite(site);
      addTearDown(c.dispose);
      await pumpEdit(tester, c, 's1');

      await tester.tap(find.text('Cookie（推荐）').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('API Key').last);
      await tester.pumpAndSettle();

      final PtSite updated = c.read(siteListProvider).valueOrNull!.single;
      expect(updated.authType, SiteAuthType.apiKey);
      expect(find.textContaining('认证方式已改为'), findsWidgets);
    });

    testWidgets('关闭「允许用 Cookie 抓取」后认证方式自动让位给 API Key', (WidgetTester tester) async {
      const PtSite site = PtSite(
        id: 's1',
        name: 'audiences',
        baseUrl: 'https://audiences.me',
      );
      final ProviderContainer c = await containerWithSite(site);
      addTearDown(c.dispose);
      await pumpEdit(tester, c, 's1');

      await tester.tap(find.text('允许用 Cookie 抓取该站数据'));
      await tester.pumpAndSettle();

      final PtSite updated = c.read(siteListProvider).valueOrNull!.single;
      expect(updated.cookieAllowed, isFalse);
      expect(updated.authType, SiteAuthType.apiKey, reason: 'Cookie 不可用时应回落到该结构的官方接口凭据');
    });
  });
}