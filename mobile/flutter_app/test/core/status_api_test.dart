// 数据 / 监护 / 签到 / 推送接口契约测试：路径、查询参数、请求体与结果解析。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/notify_settings.dart';
import 'package:pt_pocket/core/models/status_models.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/services/status_api.dart';

import '../helpers/recording_adapter.dart';

void main() {
  late RecordingAdapter adapter;
  late ApiClient client;

  setUp(() {
    adapter = RecordingAdapter(<dynamic>[]);
    final EndpointResolver resolver = EndpointResolver(
      probe: (Uri candidate, Duration timeout) async => true,
      profile: EndpointProfile(lanBaseUrl: Uri.parse('http://192.168.1.10:8000')),
    );
    client = ApiClient(resolver: resolver);
    client.raw.httpClientAdapter = adapter;
  });

  test('个人数据请求带站点过滤并解析快照汇总', () async {
    adapter.payload = <String, dynamic>{
      'sites': <dynamic>[
        <String, dynamic>{
          'siteId': 's1',
          'siteName': '站点一',
          'uploaded': 1024,
          'downloaded': 512,
          'bonus': 10,
          'seeding': 3,
          'careState': 'healthy',
          'careProgress': 0.8,
          'policy': <String, dynamic>{'minimumRatio': 0.6, 'requiresSignIn': true},
        },
        <String, dynamic>{
          'siteId': 's2',
          'siteName': '站点二',
          'uploaded': 2048,
          'downloaded': 2048,
          'careState': 'atRisk',
        },
      ],
      'generatedAt': '2026-11-03T10:00:00.000Z',
    };

    final PtDataSnapshot snapshot =
        await ProfileApi(client: client).fetch(siteIds: <String>['s1', 's2']);

    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.path, '/api/v1/profile');
    expect(adapter.requests.single.queryParameters['siteIds'], 's1,s2');

    expect(snapshot.siteCount, 2);
    expect(snapshot.totalUploaded, 3072);
    expect(snapshot.totalDownloaded, 2560);
    expect(snapshot.totalBonus, 10);
    expect(snapshot.totalSeeding, 3);
    expect(snapshot.overallRatio, closeTo(1.2, 1e-9));
    expect(snapshot.generatedAt, isNotNull);

    expect(snapshot.sites.first.careState, CareState.healthy);
    expect(snapshot.sites.first.careProgress, closeTo(0.8, 1e-9));
    expect(snapshot.sites.first.policy?.summary, contains('分享率'));
    expect(snapshot.sites[1].careState, CareState.atRisk);
    expect(snapshot.sites[1].ratio, closeTo(1, 1e-9));
  });

  test('监护事件兼容数组与 items 包裹两种返回', () async {
    adapter.payload = <dynamic>[
      <String, dynamic>{
        'id': 'e1',
        'title': '站点 A 疑似病危',
        'siteName': '站点一',
        'type': 'danger',
        'severity': 'critical',
        'occurredAt': '2026-11-01T00:00:00.000Z',
      },
    ];
    final List<MonitorEvent> events = await MonitorApi(client: client).fetchEvents(limit: 10);
    expect(adapter.requests.single.path, '/api/v1/monitor/events');
    expect(adapter.requests.single.queryParameters['limit'], 10);
    expect(events.single.type, MonitorEventType.danger);
    expect(events.single.severity, MonitorSeverity.critical);
    expect(events.single.occurredAt, isNotNull);

    adapter.payload = <String, dynamic>{
      'items': <dynamic>[
        <String, dynamic>{'id': 'e2', 'title': '站庆', 'type': 'anniversary', 'severity': 'info'},
      ],
    };
    final List<MonitorEvent> wrapped = await MonitorApi(client: client).fetchEvents();
    expect(wrapped.single.type, MonitorEventType.anniversary);
  });

  test('一键签到与单站补签的路径 / 请求体和结果解析', () async {
    adapter.payload = <String, dynamic>{
      'records': <dynamic>[
        <String, dynamic>{'siteId': 's1', 'siteName': '站点一', 'success': true},
        <String, dynamic>{'siteId': 's2', 'siteName': '站点二', 'success': false, 'message': '验证码失败'},
      ],
    };

    final SignInApi api = SignInApi(client: client);
    final SignInRunResult result = await api.runAll(siteIds: <String>['s1', 's2']);

    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.path, '/api/v1/signin/run');
    expect(
      (adapter.requests.single.data as Map<String, dynamic>)['siteIds'],
      <String>['s1', 's2'],
    );
    expect(result.successCount, 1);
    expect(result.failedCount, 1);
    expect(result.failedSites.single.siteId, 's2');

    await api.runSite('s2');
    expect(adapter.requests.last.method, 'POST');
    expect(adapter.requests.last.path, '/api/v1/sites/s2/signin');
  });

  test('签到记录列表解析', () async {
    adapter.payload = <String, dynamic>{
      'records': <dynamic>[
        <String, dynamic>{'siteId': 's1', 'siteName': '站点一', 'success': true, 'signedAt': '2026-11-03T08:00:00.000Z'},
      ],
    };

    final List<SignInRecord> records = await SignInApi(client: client).fetchRecords(limit: 5);

    expect(adapter.requests.single.path, '/api/v1/signin/records');
    expect(adapter.requests.single.queryParameters['limit'], 5);
    expect(records.single.success, isTrue);
    expect(records.single.signedAt, isNotNull);
  });

  test('测试推送携带通道名', () async {
    await NotifyApi(client: client).sendTest(NotifyChannel.telegram);

    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.path, '/api/v1/notify/test');
    expect((adapter.requests.single.data as Map<String, dynamic>)['channel'], 'telegram');
  });
}