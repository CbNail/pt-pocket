// 签到与数据 / 监护模块对齐测试（需求 7、8）：
// - 「基线不足」不得用 0 冒充；（今日上传/下载 = 当日累计 − 前一日累计）
// - 等级路线、任选条件（满足任一项）、保种契约三态的取值口径；
// - 签到下发方式（签到 / 仅模拟登录）与结果里的动作标注；
// - 界面级：签到中心与我的数据页确实把上面这些呈现出来。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/models/status_models.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/services/status_api.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:pt_pocket/core/storage/site_repository.dart';
import 'package:pt_pocket/features/monitor/signin_page.dart';
import 'package:pt_pocket/features/profile/pt_data_page.dart';
import 'package:pt_pocket/features/settings/status_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 固定单链路的 ApiClient，避免测试里触发真实选路探测。
ApiClient _client(HttpClientAdapter adapter) {
  final Dio dio = Dio()..httpClientAdapter = adapter;
  return ApiClient(
    dio: dio,
    resolver: EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => true,
      profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
    ),
  );
}

class _PayloadAdapter implements HttpClientAdapter {
  _PayloadAdapter(this.payload);

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

/// 已配对的链路档案。
class _ConfiguredEndpoint extends EndpointProfileNotifier {
  @override
  EndpointProfile build() => EndpointProfile(
        lanBaseUrl: Uri.parse('http://192.168.1.10:8000'),
        mode: LinkMode.auto,
      );
}

/// 最后一次 POST 的请求体（签到记录是 GET，别把它的 data 当成下发参数）。
Map<String, dynamic> _lastPostData(_PayloadAdapter adapter) =>
    adapter.requests.lastWhere((RequestOptions r) => r.method == 'POST').data
        as Map<String, dynamic>;

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    prefs = await SharedPreferences.getInstance();
  });

  group('今日增减与「基线不足」口径', () {
    test('没有前一自然日基线时显示「基线不足」，绝不用 0 冒充', () {
      final SiteStats withoutBaseline = SiteStats.fromJson(<String, dynamic>{
        'siteId': 's1',
        'siteName': '甲站',
        'todayUploadedBytes': 0,
        'todayDownloadedBytes': 0,
        'todayBaselineAvailable': false,
      });
      expect(withoutBaseline.todayUploadLabel, '基线不足');
      expect(withoutBaseline.todayDownloadLabel, '基线不足');
    });

    test('有基线时给出真实增量', () {
      final SiteStats withBaseline = SiteStats.fromJson(<String, dynamic>{
        'siteId': 's1',
        'siteName': '甲站',
        'todayUploadedBytes': 1073741824,
        'todayDownloadedBytes': 536870912,
        'todayBaselineAvailable': true,
      });
      expect(withBaseline.todayUploadLabel, '1.0 GB');
      expect(withBaseline.todayDownloadLabel, '512 MB');
    });

    test('快照层：后端未给基线标记时，按各站是否都有基线推断', () {
      final PtDataSnapshot partial = PtDataSnapshot(sites: <SiteStats>[
        const SiteStats(siteId: 's1', siteName: '甲', todayBaselineAvailable: true),
        const SiteStats(siteId: 's2', siteName: '乙'),
      ]);
      expect(partial.hasTodayBaseline, isFalse);
      expect(partial.todayUploadLabel, '基线不足');

      final PtDataSnapshot full = PtDataSnapshot(sites: <SiteStats>[
        const SiteStats(
          siteId: 's1',
          siteName: '甲',
          todayBaselineAvailable: true,
          todayUploadedBytes: 100,
          todayDownloadedBytes: 50,
        ),
        const SiteStats(
          siteId: 's2',
          siteName: '乙',
          todayBaselineAvailable: true,
          todayUploadedBytes: 200,
          todayDownloadedBytes: 20,
        ),
      ]);
      expect(full.hasTodayBaseline, isTrue);
      expect(full.todayUploaded, 300);
      expect(full.todayDownloaded, 70);
      expect(full.todayUploadLabel, '300 B');
    });

    test('快照显式给出总量与基线标记时以它为准', () {
      final PtDataSnapshot snapshot = PtDataSnapshot.fromJson(<String, dynamic>{
        'sites': <Map<String, dynamic>>[
          <String, dynamic>{'siteId': 's1', 'siteName': '甲'},
        ],
        'todayUploadedBytes': 1000,
        'todayDownloadedBytes': 2000,
        'todayBaselineAvailable': true,
      });
      expect(snapshot.todayUploaded, 1000);
      expect(snapshot.todayDownloaded, 2000);
      expect(snapshot.todayUploadLabel, '1000 B');
    });
  });

  group('等级路线、任选条件与保种契约', () {
    test('等级路线：有下一等级条件与只有等级名两种写法', () {
      expect(
        const SiteStats(siteId: 's', siteName: 'x', nextClass: 'Power User').classPlanLabel,
        '下一等级：Power User',
      );
      expect(
        const SiteStats(
          siteId: 's',
          siteName: 'x',
          nextClass: 'Elite',
          nextClassRequirement: '上传 ≥ 100 GB',
        ).classPlanLabel,
        '下一等级：Elite（上传 ≥ 100 GB）',
      );
      expect(const SiteStats(siteId: 's', siteName: 'x').classPlanLabel, isEmpty);
    });

    test('任选条件是「满足任一项」，并标出当前命中的那项', () {
      const SiteCarePolicy unmet = SiteCarePolicy(
        alternatives: <String>['保种 30 天', '上传满 50 GB'],
      );
      expect(unmet.alternativesLabel, '任选其一（当前均未满足）：保种 30 天 / 上传满 50 GB');

      const SiteCarePolicy met = SiteCarePolicy(
        alternatives: <String>['保种 30 天', '上传满 50 GB'],
        satisfiedAlternative: '保种 30 天',
      );
      expect(met.alternativesLabel, contains('当前已满足「保种 30 天」'));
    });

    test('保种契约三态：未提供 / 已达成 / 未达成（带项数）', () {
      expect(const SiteStats(siteId: 's', siteName: 'x').contractLabel, '数据未提供');
      expect(
        const SiteStats(siteId: 's', siteName: 'x', contractMet: true).contractLabel,
        '已达成',
      );
      expect(
        const SiteStats(siteId: 's', siteName: 'x', contractMet: false, hrCount: 3).contractLabel,
        '未达成（3 项）',
      );
      expect(
        const SiteStats(siteId: 's', siteName: 'x', contractMet: false).contractLabel,
        '未达成',
      );
    });
  });

  group('签到方式与动作', () {
    test('三种下发方式的值与解析', () {
      expect(SignInMode.fromName('both'), SignInMode.both);
      expect(SignInMode.fromName('signin'), SignInMode.signin);
      expect(SignInMode.fromName('login'), SignInMode.login);
      expect(SignInMode.fromName('unknown'), SignInMode.both);
      expect(SignInMode.both.apiValue, 'both');
    });

    test('结果里的动作：区分签到与模拟登录，缺省按签到', () {
      expect(SignInAction.fromName('login'), SignInAction.login);
      expect(SignInAction.fromName('signin'), SignInAction.signin);
      expect(SignInAction.fromName(null), SignInAction.signin);

      final SignInRecord record = SignInRecord.fromJson(<String, dynamic>{
        'siteId': 's1',
        'siteName': '甲站',
        'success': true,
        'mode': 'login',
        'signedAt': '2026-11-04T08:00:00Z',
      });
      expect(record.action, SignInAction.login);
      expect(record.signedAt, isNotNull);
    });
  });

  group('签到接口', () {
    test('批量与单站都会带上下发方式', () async {
      final _PayloadAdapter adapter = _PayloadAdapter(<String, dynamic>{'records': <dynamic>[]});
      final SignInApi api = SignInApi(client: _client(adapter));

      await api.runAll(siteIds: <String>['s1'], mode: SignInMode.login);
      await api.runSite('s1', mode: SignInMode.signin);

      expect(
        adapter.requests.map((RequestOptions r) => '${r.method} ${r.path}').toList(),
        <String>['POST /api/v1/signin/run', 'POST /api/v1/sites/s1/signin'],
      );
      expect((adapter.requests[0].data as Map<String, dynamic>)['mode'], 'login');
      expect((adapter.requests[0].data as Map<String, dynamic>)['siteIds'], <String>['s1']);
      expect((adapter.requests[1].data as Map<String, dynamic>)['mode'], 'signin');
    });
  });

  group('界面：签到中心', () {
    Future<ProviderContainer> container(_PayloadAdapter adapter) async => ProviderContainer(
          overrides: <Override>[
            sharedPreferencesProvider.overrideWithValue(prefs),
            signInApiProvider.overrideWithValue(SignInApi(client: _client(adapter))),
            endpointProfileProvider.overrideWith(_ConfiguredEndpoint.new),
          ],
        );

    testWidgets('切换下发方式后按该方式执行，结果标注动作并提供补签', (WidgetTester tester) async {
      final _PayloadAdapter adapter = _PayloadAdapter(<String, dynamic>{
        'records': <dynamic>[
          <String, dynamic>{'siteId': 's1', 'siteName': '甲站', 'success': true, 'mode': 'signin'},
          <String, dynamic>{
            'siteId': 's2',
            'siteName': '乙站',
            'success': false,
            'mode': 'login',
            'message': '登录页结构变化',
          },
        ],
        'ranAt': '2026-11-04T08:00:00Z',
      });
      final ProviderContainer c = await container(adapter);
      addTearDown(c.dispose);

      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: SignInPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 真实风险提示必须在场。
      expect(find.textContaining('并非所有站点都把程序登录 / 签到计为用户活跃'), findsOneWidget);

      await tester.tap(find.text('仅模拟登录'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('立即执行'));
      await tester.pumpAndSettle();

      expect(
        _lastPostData(adapter)['mode'],
        'login',
        reason: '选择「仅模拟登录」后必须按该方式下发',
      );

      // 结果里同时能看到成功 / 失败与本次动作。
      expect(find.text('成功'), findsWidgets);
      expect(find.text('失败'), findsWidgets);
      expect(find.text('签到'), findsWidgets);
      expect(find.text('模拟登录'), findsWidgets);
      expect(find.text('补签'), findsOneWidget);
    });

    testWidgets('默认下发方式是「签到 + 模拟登录」', (WidgetTester tester) async {
      final _PayloadAdapter adapter = _PayloadAdapter(<String, dynamic>{
        'records': <dynamic>[
          <String, dynamic>{'siteId': 's1', 'siteName': '甲站', 'success': true},
        ],
      });
      final ProviderContainer c = await container(adapter);
      addTearDown(c.dispose);

      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: SignInPage()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('立即执行'));
      await tester.pumpAndSettle();
      expect(_lastPostData(adapter)['mode'], 'both');
    });
  });

  group('界面：我的数据', () {
    testWidgets('缺基线时显示「基线不足」，有基线时显示今日增减与契约', (WidgetTester tester) async {
      final _PayloadAdapter adapter = _PayloadAdapter(<String, dynamic>{
        'sites': <Map<String, dynamic>>[
          <String, dynamic>{
            'siteId': 's1',
            'siteName': '甲站',
            'uploadedBytes': 1073741824,
            'downloadedBytes': 536870912,
            'todayUploadedBytes': 1048576,
            'todayDownloadedBytes': 524288,
            'todayBaselineAvailable': true,
            'nextClass': 'Elite',
            'nextClassRequirement': '上传 ≥ 100 GB',
            'contractMet': false,
            'hrCount': 3,
            'policy': <String, dynamic>{
              'alternatives': <String>['保种 30 天', '上传满 50 GB'],
              'satisfiedAlternative': '保种 30 天',
            },
          },
          <String, dynamic>{
            'siteId': 's2',
            'siteName': '乙站',
            'todayUploadedBytes': 0,
            'todayDownloadedBytes': 0,
            'todayBaselineAvailable': false,
          },
        ],
      });
      // 「我的数据」按本机启用站点聚合：先把两个站点写进本地清单。
      final SiteRepository repository =
          SiteRepository(prefs: PrefsStore(prefs), secure: SecureStore());
      await repository.upsert(
        const PtSite(id: 's1', name: '甲站', baseUrl: 'https://a.example'),
      );
      await repository.upsert(
        const PtSite(id: 's2', name: '乙站', baseUrl: 'https://b.example'),
      );

      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          sharedPreferencesProvider.overrideWithValue(prefs),
          profileApiProvider.overrideWithValue(ProfileApi(client: _client(adapter))),
          endpointProfileProvider.overrideWith(_ConfiguredEndpoint.new),
        ],
      );
      addTearDown(c.dispose);

      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PtDataPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 总量卡：一站的基线不足 → 整体今日增量都标「基线不足」，不显示 0。
      expect(find.text('今日上传'), findsWidgets);
      expect(find.text('今日下载'), findsWidgets);
      expect(find.text('基线不足'), findsWidgets);
      expect(find.textContaining('当日累计 − 前一自然日累计'), findsOneWidget);

      // 逐站：有基线的站点给出真实增量，并带上等级路线、保种契约与任选条件。
      expect(find.text('1.0 MB'), findsWidgets);
      expect(find.text('等级路线'), findsOneWidget);
      expect(find.text('下一等级：Elite（上传 ≥ 100 GB）'), findsOneWidget);
      expect(find.text('保种契约'), findsWidgets);
      expect(find.text('未达成（3 项）'), findsOneWidget);
      expect(find.text('任选条件'), findsOneWidget);
      expect(find.textContaining('当前已满足「保种 30 天」'), findsOneWidget);
    });
  });
}