// 「测试连接后自动保存」的界面级回归测试：无论测试成功还是失败，
// 已填内容都必须落盘，且失败原因仍要显示出来。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/downloader.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/models/service_health.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/services/site_reachability_probe.dart';
import 'package:pt_pocket/features/downloaders/downloader_add_page.dart';
import 'package:pt_pocket/features/downloaders/downloader_providers.dart';
import 'package:pt_pocket/features/search/search_providers.dart';
import 'package:pt_pocket/features/settings/connection_settings_page.dart';
import 'package:pt_pocket/features/settings/mp_add_page.dart';
import 'package:pt_pocket/features/sites/site_add_page.dart';
import 'package:pt_pocket/features/sites/site_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/recording_adapter.dart';

SiteReachabilityProbe _probeReturning(SiteProbeResult result) => SiteReachabilityProbe(
      probe: (Uri baseUrl, Duration timeout) async => result,
    );

/// 地址录入组件的主机 / 端口输入框（见 [AddressInput.keyPrefix]）。
Finder _hostField(String prefix) => find.byKey(ValueKey<String>('$prefix.host'));
Finder _portField(String prefix) => find.byKey(ValueKey<String>('$prefix.port'));

Future<ProviderContainer> _container(
  SharedPreferences prefs,
  List<Override> overrides,
) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      sharedPreferencesProvider.overrideWithValue(prefs),
      ...overrides,
    ],
  );
  // 让 AsyncNotifierProvider 完成首次构建。
  return container;
}

Future<void> _settleAfterAction(WidgetTester tester) async {
  // 录入阶段的延时探测用的是 Timer，pumpAndSettle 只等帧不等 Timer，
  // 这里显式推进一段时间，避免测试结束时留下未触发的定时器。
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    prefs = await SharedPreferences.getInstance();
  });

  /// 用大一点的画布，避免中文长文案在测试字体下触发溢出干扰断言。
  Future<void> pumpPage(
    WidgetTester tester,
    ProviderContainer container,
    Widget page,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('下载器', () {
    testWidgets('测试连接失败也会自动保存，并保留失败原因', (WidgetTester tester) async {
      final ProviderContainer container = await _container(prefs, <Override>[
        downloaderProbeProvider.overrideWithValue(
          _probeReturning(
            const SiteProbeResult(
              outcome: SiteProbeOutcome.unreachable,
              message: '连接超时：端口未开放',
            ),
          ),
        ),
      ]);
      addTearDown(container.dispose);
      await pumpPage(tester, container, const DownloaderAddPage());

      // 地址按「协议 + 主机 + 端口」分开录入，因此按 Key 定位而不是按顺序取输入框。
      await tester.enterText(find.byType(TextFormField).at(0), '主力 qB');
      await tester.enterText(_hostField('downloader'), '192.168.1.10');
      await tester.enterText(_portField('downloader'), '8080');
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      await _settleAfterAction(tester);

      final List<DownloaderConfig> list =
          container.read(downloaderListProvider).valueOrNull ?? const <DownloaderConfig>[];
      expect(list, hasLength(1), reason: '测试失败也必须保存已填内容');
      expect(list.single.name, '主力 qB');
      expect(list.single.baseUrl, 'http://192.168.1.10:8080');
      expect(list.single.health, DownloaderHealth.danger, reason: '失败结果应记入健康状态');
      // 失败原因仍然可见
      expect(find.textContaining('连接超时'), findsWidgets);
    });

    testWidgets('重复测试不会重复建档', (WidgetTester tester) async {
      final ProviderContainer container = await _container(prefs, <Override>[
        downloaderProbeProvider.overrideWithValue(
          _probeReturning(const SiteProbeResult(outcome: SiteProbeOutcome.reachable)),
        ),
      ]);
      addTearDown(container.dispose);
      await pumpPage(tester, container, const DownloaderAddPage());

      await tester.enterText(find.byType(TextFormField).at(0), '备用 tr');
      await tester.enterText(_hostField('downloader'), 'tr.example');
      await tester.enterText(_portField('downloader'), '9091');
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      await _settleAfterAction(tester);
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      await _settleAfterAction(tester);

      final List<DownloaderConfig> list =
          container.read(downloaderListProvider).valueOrNull ?? const <DownloaderConfig>[];
      expect(list, hasLength(1));
      expect(list.single.baseUrl, 'http://tr.example:9091');
      expect(list.single.health, DownloaderHealth.ok);
    });
  });

  group('MoviePilot', () {
    testWidgets('测试后保存内外网两条通道并记录健康', (WidgetTester tester) async {
      final ProviderContainer container = await _container(prefs, <Override>[
        mpProbeProvider.overrideWithValue(
          _probeReturning(const SiteProbeResult(outcome: SiteProbeOutcome.unauthorized)),
        ),
      ]);
      addTearDown(container.dispose);
      await pumpPage(tester, container, const MpAddPage());

      await tester.enterText(find.byType(TextFormField).at(0), '家宽 MP');
      await tester.enterText(_hostField('mp.lan'), '192.168.1.10');
      // 内外网改成一个地址区 + 左侧切换：切到「外网」再填外网地址。
      await tester.tap(find.text('外网'));
      await tester.pumpAndSettle();
      await tester.enterText(_hostField('mp.wan'), 'mp.example.com');
      await tester.enterText(_portField('mp.wan'), '5888');
      await tester.tap(find.text('测试两条通道'));
      await tester.pumpAndSettle();
      await _settleAfterAction(tester);

      final List<MpInstance> list =
          container.read(mpListProvider).valueOrNull ?? const <MpInstance>[];
      expect(list, hasLength(1));
      expect(list.single.name, '家宽 MP');
      expect(list.single.lanBaseUrl, 'http://192.168.1.10:3000');
      expect(list.single.wanBaseUrl, 'https://mp.example.com:5888');
      expect(list.single.health, ServiceHealth.ok);
    });
  });

  group('站点', () {
    testWidgets('测试后自动保存站点', (WidgetTester tester) async {
      final ProviderContainer container = await _container(prefs, <Override>[
        siteProbeProvider.overrideWithValue(
          _probeReturning(const SiteProbeResult(outcome: SiteProbeOutcome.reachable)),
        ),
      ]);
      addTearDown(container.dispose);
      await pumpPage(tester, container, const SiteAddPage());

      final Finder fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '测试站点');
      await tester.enterText(fields.at(1), 'https://site.example');
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      await _settleAfterAction(tester);

      final List<PtSite> sites =
          container.read(siteListProvider).valueOrNull ?? const <PtSite>[];
      expect(sites, hasLength(1));
      expect(sites.single.name, '测试站点');
      expect(sites.single.baseUrl, 'https://site.example');
    });
  });

  group('连接与服务', () {
    testWidgets('测试两条通道后自动保存地址与链路模式', (WidgetTester tester) async {
      final Dio dio = Dio()
        ..httpClientAdapter = RecordingAdapter(<String, dynamic>{'status': 'ok'});
      final ProviderContainer container = await _container(prefs, <Override>[
        healthProbeProvider.overrideWithValue(HttpHealthProbe(dio: dio)),
      ]);
      addTearDown(container.dispose);
      await pumpPage(tester, container, const ConnectionSettingsPage());

      await tester.enterText(_hostField('endpoint.lan'), '192.168.1.10');
      await tester.enterText(_portField('endpoint.lan'), '8000');
      // 内外网改成一个地址区 + 左侧切换：切到「外网」再填外网地址。
      await tester.tap(find.text('外网'));
      await tester.pumpAndSettle();
      await tester.enterText(_hostField('endpoint.wan'), 'nas.example.com');
      await tester.enterText(_portField('endpoint.wan'), '5888');
      await tester.tap(find.text('重新检测两条通道'));
      await tester.pumpAndSettle();
      await _settleAfterAction(tester);

      final EndpointProfile profile = container.read(endpointProfileProvider);
      expect(profile.lanBaseUrl.toString(), 'http://192.168.1.10:8000');
      expect(profile.wanBaseUrl.toString(), 'https://nas.example.com:5888');
      expect(profile.mode, LinkMode.auto);
    });
  });
}