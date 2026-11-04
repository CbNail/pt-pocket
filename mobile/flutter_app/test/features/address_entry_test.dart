// 地址录入与连通性实时状态的回归测试（本轮需求 1、2）。
//
// 覆盖三件事：
// 1. http / https 由用户点选、端口有默认值且可改、主机与端口分开录入后的拼装口径；
// 2. 填入地址并检测后，地址旁出现连通勾 / 叉，整体连通情况在「服务地址」框底部给出；
// 3. 探测结论落盘：重新进入页面时先呈现上次结论，而不是一律「未检测」
//    （由 AddressProbeController + ProbeResultStore 的读回行为保证）。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/network/address_probe_controller.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/network/url_utils.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/probe_result_store.dart';
import 'package:pt_pocket/features/settings/connection_settings_page.dart';
import 'package:pt_pocket/shared/widgets/address_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/recording_adapter.dart';

/// 任何请求都失败的适配器：模拟域名解析失败 / 端口不通。
class _FailingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'Failed host lookup: ${options.uri.host}',
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _container(SharedPreferences prefs, List<Override> overrides) async {
  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      sharedPreferencesProvider.overrideWithValue(prefs),
      ...overrides,
    ],
  );
  // 让 AsyncNotifierProvider 完成首次构建。
  container.read(prefsStoreProvider);
  return container;
}

Finder _hostField(String prefix) => find.byKey(ValueKey<String>('$prefix.host'));
Finder _portField(String prefix) => find.byKey(ValueKey<String>('$prefix.port'));

Future<void> _settleAfterAction(WidgetTester tester) async {
  // 录入阶段的延时探测用的是 Timer，pumpAndSettle 只等帧不等 Timer，
  // 这里显式推进一段时间，既让延时探测跑完，也避免测试结束留下未触发的定时器。
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container, Widget page) async {
  // 画布放大，避免中文长文案在测试字体下触发溢出干扰断言。
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

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    prefs = await SharedPreferences.getInstance();
  });

  group('地址拼装与默认端口', () {
    test('协议默认端口：http 80 / https 443', () {
      expect(UrlUtils.defaultPort('http'), 80);
      expect(UrlUtils.defaultPort('https'), 443);
      expect(UrlUtils.defaultPort('other'), 80);
    });

    test('主机与端口分开录入后拼成完整地址', () {
      expect(
        UrlUtils.compose(scheme: 'http', host: '192.168.1.10', port: '8000').toString(),
        'http://192.168.1.10:8000',
      );
      expect(
        UrlUtils.compose(scheme: 'https', host: 'cc.example.com', port: '8900', path: '/cc')
            .toString(),
        'https://cc.example.com:8900/cc',
      );
      // 协议默认端口不写进地址，保持地址干净。
      expect(UrlUtils.compose(scheme: 'https', host: 'h', port: '443').toString(), 'https://h');
    });

    test('端口留空回落默认端口，填错则明确拒绝，主机为空一律拒绝', () {
      expect(UrlUtils.compose(scheme: 'https', host: 'h', port: '').toString(), 'https://h');
      expect(UrlUtils.compose(scheme: 'http', host: 'h', port: '   ').toString(), 'http://h');
      expect(UrlUtils.compose(scheme: 'https', host: '', port: '443'), isNull);
      expect(UrlUtils.compose(scheme: 'https', host: '   ', port: '443'), isNull);
      expect(UrlUtils.compose(scheme: 'https', host: 'h', port: '70000'), isNull);
      expect(UrlUtils.compose(scheme: 'https', host: 'h', port: '0'), isNull);
      expect(UrlUtils.compose(scheme: 'https', host: 'h', port: 'abc'), isNull);
    });

    test('切换协议时端口兜底：只换默认端口，用户填过的端口不动', () {
      expect(UrlUtils.adjustPortForScheme(scheme: 'https', currentPort: '80'), '443');
      expect(UrlUtils.adjustPortForScheme(scheme: 'http', currentPort: '443'), '80');
      expect(UrlUtils.adjustPortForScheme(scheme: 'https', currentPort: '5888'), '5888');
      expect(UrlUtils.adjustPortForScheme(scheme: 'https', currentPort: ''), '443');
    });

    test('粘贴整条 URL 会被拆成协议 / 主机 / 端口 / 子路径', () {
      final AddressParts parts = UrlUtils.split('https://pt.example.xyz:5888/ptp');
      expect(parts.scheme, 'https');
      expect(parts.host, 'pt.example.xyz');
      expect(parts.port, 5888);
      expect(parts.portText, '5888');
      expect(parts.path, '/ptp');

      final AddressParts bare = UrlUtils.split('192.168.5.206:45005');
      expect(bare.scheme, 'http');
      expect(bare.host, '192.168.5.206');
      expect(bare.port, 45005);

      // 只有协议没有主机、整串空白、主机里带空格 → 拆不出任何部分
      // （页面据此提示地址不完整，而不是拼出一个看似合法的地址）。
      expect(UrlUtils.split('http://').isEmpty, isTrue);
      expect(UrlUtils.split('   ').isEmpty, isTrue);
      expect(UrlUtils.split('https://not a host').isEmpty, isTrue);
    });
  });

  group('连通状态的文字口径', () {
    test('未配置 / 未检测 / 不可达 / 地址通服务未就绪 / 已连通 五态可区分', () {
      expect(
        AddressPairSummary.describe(const AddressSummaryItem(name: '内网', configured: false)),
        '未配置',
      );
      expect(
        AddressPairSummary.describe(const AddressSummaryItem(name: '内网', configured: true)),
        '未检测',
      );
      expect(
        AddressPairSummary.describe(
          const AddressSummaryItem(name: '内网', configured: true, probing: true),
        ),
        '检测中…',
      );

      expect(describeProbe(null), '未检测');
      expect(describeProbe(ProbeSnapshot(reachable: false, usable: false, probedAt: DateTime(2026))), '不可达');
      expect(
        describeProbe(ProbeSnapshot(reachable: true, usable: false, probedAt: DateTime(2026))),
        '地址通、服务未就绪',
      );
      expect(
        describeProbe(ProbeSnapshot(reachable: true, usable: true, probedAt: DateTime(2026))),
        '已连通',
      );
    });
  });

  group('重进页面时的状态来源', () {
    test('已落盘的探测结论会被直接读回，不会退化成「未检测」', () async {
      final ProbeResultStore store = ProbeResultStore(prefs: PrefsStore(prefs));
      await store.write(
        'endpoint.lan',
        ProbeSnapshot(
          reachable: true,
          usable: true,
          statusCode: 200,
          message: '服务已连通（HTTP 200）',
          url: 'http://192.168.1.10:8000',
          probedAt: DateTime(2026, 1, 1),
        ),
      );

      final AddressProbeController controller = AddressProbeController(
        store: store,
        // 本用例只验证「读回」，探测函数不会被调用。
        probe: (Uri target, Duration timeout) async =>
            ProbeSnapshot(reachable: false, usable: false, probedAt: DateTime(2026)),
      );
      addTearDown(controller.dispose);

      final ProbeSnapshot? restored = controller.snapshot('endpoint.lan');
      expect(restored, isNotNull);
      expect(restored!.usable, isTrue);
      expect(describeProbe(restored), '已连通');
      expect(controller.isProbing('endpoint.lan'), isFalse);
    });

    test('新探测结论会覆盖落盘值（状态随用户操作实时变化）', () async {
      final ProbeResultStore store = ProbeResultStore(prefs: PrefsStore(prefs));
      await store.write(
        'endpoint.wan',
        ProbeSnapshot(reachable: true, usable: true, probedAt: DateTime(2026, 1, 1)),
      );

      final AddressProbeController controller = AddressProbeController(
        store: store,
        probe: (Uri target, Duration timeout) async => ProbeSnapshot(
          reachable: false,
          usable: false,
          message: '连接超时',
          probedAt: DateTime(2026, 2, 1),
        ),
      );
      addTearDown(controller.dispose);

      expect(describeProbe(controller.snapshot('endpoint.wan')), '已连通');
      await controller.probeNow('endpoint.wan', Uri.parse('https://nas.example.com:5888'));
      expect(describeProbe(controller.snapshot('endpoint.wan')), '不可达');
      expect(describeProbe(store.read('endpoint.wan')), '不可达', reason: '新结论要落盘给下次进入用');
    });
  });

  group('内外网切换（同一地址区 + 左侧切换）', () {
    testWidgets('一次只显示一条通道，切换后已填的值不串', (WidgetTester tester) async {
      final Dio dio = Dio()
        ..httpClientAdapter = RecordingAdapter(<String, dynamic>{'status': 'ok'});
      final ProviderContainer container = await _container(prefs, <Override>[
        healthProbeProvider.overrideWithValue(HttpHealthProbe(dio: dio)),
      ]);
      addTearDown(container.dispose);
      await _pumpPage(tester, container, const ConnectionSettingsPage());

      // 默认展示内网：外网输入框不在树上（不再两栏并排）。
      expect(find.byKey(const ValueKey<String>('endpoint.lan.host')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('endpoint.wan.host')), findsNothing);

      await tester.enterText(_hostField('endpoint.lan'), '192.168.1.10');
      await tester.enterText(_portField('endpoint.lan'), '8000');

      await tester.tap(find.text('外网'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('endpoint.wan.host')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('endpoint.lan.host')), findsNothing);

      await tester.enterText(_hostField('endpoint.wan'), 'nas.example.com');
      await tester.enterText(_portField('endpoint.wan'), '5888');

      // 切回内网：内网填过的值必须还在。
      await tester.tap(find.text('内网'));
      await tester.pumpAndSettle();
      final TextField lanHost = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('endpoint.lan.host')),
      );
      expect(lanHost.controller?.text, '192.168.1.10');

      await tester.tap(find.text('保存连接设置'));
      await _settleAfterAction(tester);

      // 两条通道各自落到自己的字段，没有互相覆盖。
      final EndpointProfile profile = container.read(endpointProfileProvider);
      expect(profile.lanBaseUrl?.toString(), 'http://192.168.1.10:8000');
      expect(profile.wanBaseUrl?.toString(), 'https://nas.example.com:5888');
      // 底部整体连通情况同时列出两条通道（切换不影响整体视图）。
      expect(find.text('内网：'), findsOneWidget);
      expect(find.text('外网：'), findsOneWidget);
    });
  });

  group('连接与服务：实时连通显示', () {
    testWidgets('检测后地址旁出现勾，服务地址框底部给出整体连通情况', (WidgetTester tester) async {
      final Dio dio = Dio()
        ..httpClientAdapter = RecordingAdapter(<String, dynamic>{'status': 'ok'});
      final ProviderContainer container = await _container(prefs, <Override>[
        healthProbeProvider.overrideWithValue(HttpHealthProbe(dio: dio)),
      ]);
      addTearDown(container.dispose);
      await _pumpPage(tester, container, const ConnectionSettingsPage());

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

      // 两条通道各自打勾。
      expect(find.byIcon(Icons.check_circle_outline), findsWidgets);
      // 底部整体情况逐条列出通道结论，并给出当前优先链路。
      expect(find.text('内网：'), findsOneWidget);
      expect(find.text('外网：'), findsOneWidget);
      expect(find.text('已连通'), findsNWidgets(2));
      expect(find.text('整体情况：当前优先走内网'), findsOneWidget);
      // 已经检测过，就不该再显示「未检测」。
      expect(find.text('未检测'), findsNothing);
    });

    testWidgets('地址不可达时打叉，并给出「当前没有可用通道」', (WidgetTester tester) async {
      final Dio dio = Dio()..httpClientAdapter = _FailingAdapter();
      final ProviderContainer container = await _container(prefs, <Override>[
        healthProbeProvider.overrideWithValue(HttpHealthProbe(dio: dio)),
      ]);
      addTearDown(container.dispose);
      await _pumpPage(tester, container, const ConnectionSettingsPage());

      await tester.enterText(_hostField('endpoint.lan'), '192.168.1.10');
      await tester.enterText(_portField('endpoint.lan'), '8000');
      await tester.tap(find.text('重新检测两条通道'));
      await tester.pumpAndSettle();
      await _settleAfterAction(tester);

      expect(find.byIcon(Icons.cancel_outlined), findsWidgets);
      expect(find.text('不可达'), findsWidgets);
      // 内网不可达、外网未配置 → 没有可用通道。
      expect(find.text('外网：'), findsOneWidget);
      expect(find.text('整体情况：当前没有可用通道'), findsOneWidget);
    });
  });
}