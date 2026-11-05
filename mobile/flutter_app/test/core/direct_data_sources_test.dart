// 站点数据组装与下载器通道测试（需求 2 / 3 / 5）：
// - 由直连快照组装 SiteStats：字段映射、签到标注「未采集」、今日增量与基线标记；
// - 失败时保留站点身份并写明原因分类；
// - 下载器通道：qBittorrent 直连优先、失败且后端可用时回退、非 qB 引擎只走后端。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/direct/downloader_gateway.dart';
import 'package:pt_pocket/core/direct/nexusphp_client.dart';
import 'package:pt_pocket/core/direct/qbittorrent_client.dart';
import 'package:pt_pocket/core/direct/site_stats_service.dart';
import 'package:pt_pocket/core/direct/transmission_client.dart';
import 'package:pt_pocket/core/direct/stats_history_store.dart';
import 'package:pt_pocket/core/models/downloader.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/models/status_models.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/services/downloader_api.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const PtSite _site = PtSite(
  id: 'site-1',
  name: 'CyanBug',
  baseUrl: 'https://cyanbug.net',
  credentialConfigured: true,
);

const SiteUserSnapshot _snapshot = SiteUserSnapshot(
  siteId: 'site-1',
  siteName: 'CyanBug',
  username: 'CBNail',
  userClass: 'Power User',
  uploadedBytes: 1 << 40,
  downloadedBytes: 1 << 32,
  ratio: 30.74,
  bonus: 1975,
  seedingCount: 299,
  leechingCount: 3,
  invites: 1,
  unreadMessages: 2,
  hrCount: 0,
  hrSummary: '0/0/15',
  missing: <String>['连接数'],
);

/// 测试用的 ApiClient 替身：解析器永远探测失败，因此不会真的发出请求；
/// 只有「后端回退」路径才会用到它，而这些替身都覆盖了对应方法。
ApiClient _unusedApiClient() => ApiClient(
      resolver: EndpointResolver(
        probe: (Uri candidate, Duration timeout) async => false,
        profile: EndpointProfile(lanBaseUrl: Uri.parse('http://127.0.0.1:8000')),
      ),
    );

void main() {
  group('SiteStats 组装', () {
    late SiteStatsService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      service = SiteStatsService(
        client: NexusPhpClient(Dio()),
        history: StatsHistoryStore(prefs: PrefsStore(await SharedPreferences.getInstance())),
      );
    });

    test('字段映射：数值、等级路线与「未采集」标注', () {
      final SiteStats stats = service.build(site: _site, snapshot: _snapshot);
      expect(stats.siteId, 'site-1');
      expect(stats.siteName, 'CyanBug');
      expect(stats.username, 'CBNail');
      expect(stats.userClass, 'Power User');
      expect(stats.uploadedBytes, 1 << 40);
      expect(stats.bonus, 1975);
      expect(stats.seedingCount, 299);
      expect(stats.ratioLabel, '30.74');
      expect(stats.invites, 1);
      expect(stats.unreadMessages, 2);
      expect(stats.refreshState, SiteRefreshState.refreshed);
      expect(stats.signInKnown, isFalse);
      expect(stats.signInLabel, '未采集');
      expect(stats.signInStatusLabel, '签到状态未采集');
      expect(stats.hourlyBonus, 0, reason: '只有一次采样时不给时魔，避免编造');
      expect(stats.hourlyBonusLabel, '—');
      expect(stats.todayBaselineAvailable, isFalse);
      expect(stats.todayUploadLabel, '基线不足');
      expect(stats.levelSteps.length, 8);
      expect(stats.promotionNote.contains('NexusPHP'), isTrue);
      expect(stats.contractMet, isTrue, reason: 'H&R 为 0 视为契约达成');
      expect(stats.refreshMessage.contains('未提供：连接数'), isTrue);
    });

    test('分享率 ∞ 时展示 ∞，进度仍可判断', () {
      final SiteStats stats = service.build(
        site: _site,
        snapshot: const SiteUserSnapshot(
          siteId: 'site-1',
          siteName: 'CyanBug',
          uploadedBytes: 1 << 40,
          downloadedBytes: 0,
          infiniteRatio: true,
        ),
      );
      expect(stats.ratio, double.infinity);
      expect(stats.ratioLabel, '∞');
    });

    test('失败：保留站点名并带上原因分类', () {
      final SiteStats stats = service.failure(
        site: _site,
        error: const SiteFetchException(
          kind: SiteFetchFailureKind.missingCredential,
          message: '未保存 Cookie',
        ),
      );
      expect(stats.siteName, 'CyanBug');
      expect(stats.refreshState, SiteRefreshState.notLoggedIn);
      expect(stats.refreshMessage.contains('缺少凭据'), isTrue);
      expect(stats.uploadedBytes, 0);
      expect(stats.signInKnown, isFalse);
    });

    test('站点返回 500 时归类为失败而不是抛出', () async {
      // 用假适配器把站点响应固定成 500：既不打真实网络，又能验证失败归类。
      final Dio dio = Dio()
        ..httpClientAdapter = _AlwaysStatus(500);
      final SiteStats stats = await SiteStatsService(
        client: NexusPhpClient(dio),
        history: StatsHistoryStore(prefs: PrefsStore(await SharedPreferences.getInstance())),
      ).fetchSite(_site, credential: <String, dynamic>{'cookie': 'a=1'});
      expect(stats.refreshState, isNot(SiteRefreshState.refreshed));
      expect(stats.refreshMessage.isNotEmpty, isTrue);
      expect(stats.siteName, 'CyanBug');
    });
  });

  group('下载器通道', () {
    test('qBittorrent 直连成功时不走后端', () async {
      final DownloaderGateway gateway = DownloaderGateway(
        () => true,
        (String id) => const DownloaderConfig(
          id: 'dl-1',
          name: 'qb',
          kind: DownloaderKind.qbittorrent,
          baseUrl: 'http://127.0.0.1:8080',
          username: 'admin',
        ),
        (String id) async => null,
        nas: _ThrowingNas(),
        qb: _StubQb(tasks: <DownloaderTask>[
          const DownloaderTask(hash: 'h1', name: '直连任务'),
        ]),
        tr: _StubTr(),
      );
      final List<DownloaderTask> tasks = await gateway.fetchTasks('dl-1');
      expect(tasks.single.name, '直连任务');
    });

    test('直连缺凭据且后端可用时回退后端', () async {
      final DownloaderGateway gateway = DownloaderGateway(
        () => true,
        (String id) => const DownloaderConfig(
          id: 'dl-1',
          name: 'qb',
          kind: DownloaderKind.qbittorrent,
          baseUrl: 'http://127.0.0.1:8080',
        ),
        (String id) async => null,
        nas: _NasStub(),
        qb: _StubQb(throwMissingCredential: true),
        tr: _StubTr(),
      );
      final List<DownloaderTask> tasks = await gateway.fetchTasks('dl-1');
      expect(tasks.single.name, '来自后端');
    });

    test('后端不可用且直连缺凭据时，给出可执行的原因', () async {
      final DownloaderGateway gateway = DownloaderGateway(
        () => false,
        (String id) => const DownloaderConfig(
          id: 'dl-1',
          name: 'qb',
          kind: DownloaderKind.qbittorrent,
          baseUrl: 'http://127.0.0.1:8080',
        ),
        (String id) async => null,
        nas: _NasStub(),
        qb: _StubQb(throwMissingCredential: true),
        tr: _StubTr(),
      );
      expect(
        () => gateway.fetchTasks('dl-1'),
        throwsA(
          isA<DownloaderFetchException>().having(
            (DownloaderFetchException e) => e.kind,
            'kind',
            DownloaderFailureKind.missingCredential,
          ),
        ),
      );
    });

    test('Transmission 直连优先，后端只做回退', () async {
      final DownloaderGateway gateway = DownloaderGateway(
        () => true,
        (String id) => const DownloaderConfig(
          id: 'dl-2',
          name: 'tr',
          kind: DownloaderKind.transmission,
          baseUrl: 'http://127.0.0.1:9091',
        ),
        (String id) async => null,
        nas: _NasStub(),
        qb: _StubQb(),
        tr: _StubTr(tasks: <DownloaderTask>[
          const DownloaderTask(hash: 'tr-1', name: '直连 TR 任务'),
        ]),
      );
      final List<DownloaderTask> tasks = await gateway.fetchTasks('dl-2');
      expect(tasks.single.name, '直连 TR 任务');
    });

    test('Transmission 直连缺凭据且后端可用时回退后端', () async {
      final DownloaderGateway gateway = DownloaderGateway(
        () => true,
        (String id) => const DownloaderConfig(
          id: 'dl-2',
          name: 'tr',
          kind: DownloaderKind.transmission,
          baseUrl: 'http://127.0.0.1:9091',
        ),
        (String id) async => null,
        nas: _NasStub(),
        qb: _StubQb(),
        tr: _StubTr(throwMissingCredential: true),
      );
      final List<DownloaderTask> tasks = await gateway.fetchTasks('dl-2');
      expect(tasks.single.name, '来自后端');
    });

    test('Aria2 只走后端；后端不可用时说明清楚', () async {
      final DownloaderGateway gateway = DownloaderGateway(
        () => false,
        (String id) => const DownloaderConfig(
          id: 'dl-3',
          name: 'a2',
          kind: DownloaderKind.aria2,
          baseUrl: 'http://127.0.0.1:6800',
        ),
        (String id) async => null,
        nas: _NasStub(),
        qb: _StubQb(),
        tr: _StubTr(),
      );
      expect(
        () => gateway.fetchTasks('dl-3'),
        throwsA(
          isA<DownloaderFetchException>().having(
            (DownloaderFetchException e) => e.message,
            'message',
            contains('需要 NAS 后端转发'),
          ),
        ),
      );
    });

    test('下载器已删除时报「已不存在」', () async {
      final DownloaderGateway gateway = DownloaderGateway(
        () => true,
        (String id) => null,
        (String id) async => null,
        nas: _NasStub(),
        qb: _StubQb(),
        tr: _StubTr(),
      );
      expect(
        () => gateway.fetchTasks('missing'),
        throwsA(isA<DownloaderFetchException>()),
      );
    });
  });
}

class _StubQb extends QbittorrentClient {
  _StubQb({this.tasks = const <DownloaderTask>[], this.throwMissingCredential = false})
      : super(Dio());

  final List<DownloaderTask> tasks;
  final bool throwMissingCredential;

  @override
  Future<List<DownloaderTask>> fetchTasks(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    if (throwMissingCredential) {
      throw const DownloaderFetchException(
        kind: DownloaderFailureKind.missingCredential,
        message: '缺少 WebUI 用户名或密码',
      );
    }
    return tasks;
  }
}

/// Transmission 直连桩：只覆盖本文件用到的取任务。
class _StubTr extends TransmissionClient {
  _StubTr({this.tasks = const <DownloaderTask>[], this.throwMissingCredential = false})
      : super(Dio());

  final List<DownloaderTask> tasks;
  final bool throwMissingCredential;

  @override
  Future<List<DownloaderTask>> fetchTasks(
    DownloaderConfig config, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    if (throwMissingCredential) {
      throw const DownloaderFetchException(
        kind: DownloaderFailureKind.missingCredential,
        message: '缺少 RPC 用户名或密码',
      );
    }
    return tasks;
  }
}

class _NasStub extends DownloaderApi {
  _NasStub() : super(client: _unusedApiClient());

  @override
  Future<List<DownloaderTask>> fetchTasks(String downloaderId) async => <DownloaderTask>[
        const DownloaderTask(hash: 'nas-1', name: '来自后端', state: TaskState.seeding),
      ];

  @override
  Future<DownloaderTaskOption> fetchTaskOptions(String downloaderId) async =>
      const DownloaderTaskOption(categories: <String>['后端分类']);
}

class _ThrowingNas extends DownloaderApi {
  _ThrowingNas() : super(client: _unusedApiClient());

  @override
  Future<List<DownloaderTask>> fetchTasks(String downloaderId) async =>
      throw StateError('不应调用 NAS 后端');
}


/// 固定返回某个 HTTP 状态的适配器（不产生真实网络访问）。
class _AlwaysStatus implements HttpClientAdapter {
  _AlwaysStatus(this.status);

  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString('server error', status);

  @override
  void close({bool force = false}) {}
}
