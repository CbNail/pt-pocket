// 下载器接口契约测试：请求路径、方法、请求体，以及跨引擎任务字段归一化。
//
// 用记录型 HttpClientAdapter 拦截 dio 请求，不产生真实网络访问。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/downloader.dart';
import 'package:pt_pocket/core/network/api_client.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/services/downloader_api.dart';

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

  test('任务列表兼容 qBittorrent 与 Transmission 字段', () async {
    adapter.payload = <dynamic>[
      <String, dynamic>{
        'hash': 'h1',
        'name': 'A',
        'size': 1000,
        'completed': 500,
        'state': 'downloading',
        'dlspeed': 100,
        'upspeed': 20,
        'eta': 60,
        'save_path': '/downloads/PT',
        'category': 'pt',
        'ratio': 0.5,
      },
      <String, dynamic>{
        'hashString': 'h2',
        'name': 'B',
        'totalSize': 2000,
        'percentDone': 0.25,
        'status': 'stopped',
        'rateDownload': 10,
        'rateUpload': 5,
        'eta': -1,
        'downloadDir': '/downloads/PT2',
        'labels': <String>['pt'],
      },
    ];

    final List<DownloaderTask> tasks = await api.fetchTasks('d1');

    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.path, '/api/v1/downloaders/d1/tasks');
    expect(tasks, hasLength(2));

    expect(tasks[0].hash, 'h1');
    expect(tasks[0].state, TaskState.downloading);
    expect(tasks[0].progress, closeTo(0.5, 1e-9));
    expect(tasks[0].savePath, '/downloads/PT');
    expect(tasks[0].category, 'pt');
    expect(tasks[0].etaSeconds, 60);

    expect(tasks[1].hash, 'h2');
    expect(tasks[1].state, TaskState.paused);
    expect(tasks[1].sizeBytes, 2000);
    expect(tasks[1].completedBytes, 500);
    expect(tasks[1].progress, closeTo(0.25, 1e-9));
    expect(tasks[1].category, 'pt');
    expect(tasks[1].etaSeconds, -1);
  });

  test('暂停 / 继续 / 移除任务的下发路径与请求体正确', () async {
    await api.pause('d1', <String>['h1']);
    await api.resume('d1', <String>['h1', 'h2']);
    await api.remove('d1', <String>['h1'], deleteFiles: true);

    expect(
      adapter.requests.map((RequestOptions r) => '${r.method} ${r.path}').toList(),
      <String>[
        'POST /api/v1/downloaders/d1/tasks/pause',
        'POST /api/v1/downloaders/d1/tasks/resume',
        'POST /api/v1/downloaders/d1/tasks/remove',
      ],
    );

    final Map<String, dynamic> pauseBody = adapter.requests[0].data as Map<String, dynamic>;
    expect(pauseBody['hashes'], <String>['h1']);

    final Map<String, dynamic> resumeBody = adapter.requests[1].data as Map<String, dynamic>;
    expect(resumeBody['hashes'], <String>['h1', 'h2']);

    final Map<String, dynamic> removeBody = adapter.requests[2].data as Map<String, dynamic>;
    expect(removeBody['hashes'], <String>['h1']);
    expect(removeBody['deleteFiles'], isTrue);
  });

  test('返回非数组时抛出结构异常，避免把结构问题伪装成"没有任务"', () async {
    adapter.payload = <String, dynamic>{'unexpected': true};

    await expectLater(
      api.fetchTasks('d1'),
      throwsA(
        isA<Exception>().having(
          (Exception error) => error.toString(),
          'toString',
          contains('结构不符合预期'),
        ),
      ),
    );
  });
}