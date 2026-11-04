// qBittorrent 直连测试（需求 5）：
// - 登录：请求路径 /api/v2/auth/login、表单字段、SID 会话复用；
// - 任务列表：字段映射（状态 / 速度 / 进度 / 标签 / tracker / 加入时间）与状态归一化；
// - 写操作：暂停 / 继续 / 删除 / 分类 / 标签 / 路径的路径与参数；
// - 失败分类：密码错 / 403 白名单 / 结构异常。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/direct/qbittorrent_client.dart';
import 'package:pt_pocket/core/models/downloader.dart';

class _FakeQb implements HttpClientAdapter {
  _FakeQb(this.handlers);

  final Map<String, ResponseBody Function(RequestOptions options)> handlers;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final String key = options.uri.path;
    final ResponseBody Function(RequestOptions)? handler = handlers[key];
    if (handler == null) {
      return ResponseBody.fromString('not found', 404);
    }
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok(String body, {List<String>? cookies}) => ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/plain'],
        'set-cookie': ?cookies,
      },
    );

/// JSON 响应：内容类型必须是 application/json，Dio 才会按 `ResponseType.json` 解码。
ResponseBody _json(Object payload) => ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

void main() {
  late DownloaderConfig config;

  setUp(() {
    config = const DownloaderConfig(
      id: 'dl-1',
      name: 'qb 主下载器',
      kind: DownloaderKind.qbittorrent,
      baseUrl: 'http://192.168.5.206:8080',
      username: 'admin',
      credentialConfigured: true,
    );
  });

  test('状态归一化覆盖 qBittorrent 全部常见状态', () {
    expect(QbittorrentClient.taskStateOf('downloading'), TaskState.downloading);
    expect(QbittorrentClient.taskStateOf('stalledDL'), TaskState.downloading);
    expect(QbittorrentClient.taskStateOf('metaDL'), TaskState.downloading);
    expect(QbittorrentClient.taskStateOf('uploading'), TaskState.seeding);
    expect(QbittorrentClient.taskStateOf('stalledUP'), TaskState.seeding);
    expect(QbittorrentClient.taskStateOf('pausedUP'), TaskState.paused);
    expect(QbittorrentClient.taskStateOf('pausedDL'), TaskState.paused);
    expect(QbittorrentClient.taskStateOf('queuedUP'), TaskState.queued);
    expect(QbittorrentClient.taskStateOf('checkingUP'), TaskState.checking);
    expect(QbittorrentClient.taskStateOf('checkingResumeData'), TaskState.checking);
    expect(QbittorrentClient.taskStateOf('error'), TaskState.error);
    expect(QbittorrentClient.taskStateOf('missingFiles'), TaskState.error);
    expect(QbittorrentClient.taskStateOf(''), TaskState.unknown);
  });

  test('任务字段映射', () {
    final DownloaderTask task = QbittorrentClient.parseTorrentJson(<String, dynamic>{
      'hash': 'abc123',
      'name': '仙逆 S01E01',
      'size': 4294967296,
      'completed': 2147483648,
      'state': 'downloading',
      'dlspeed': 2048,
      'upspeed': 512,
      'eta': 600,
      'save_path': '/downloads/PT',
      'category': 'movie',
      'tags': 'pt, 仙逆 ,',
      'ratio': 2.5,
      'tracker': 'udp://tracker.example:6969/announce',
      'added_on': 1762000000,
    });
    expect(task.hash, 'abc123');
    expect(task.sizeBytes, 4294967296);
    expect(task.completedBytes, 2147483648);
    expect(task.state, TaskState.downloading);
    expect(task.downloadSpeed, 2048);
    expect(task.uploadSpeed, 512);
    expect(task.etaSeconds, 600);
    expect(task.savePath, '/downloads/PT');
    expect(task.category, 'movie');
    expect(task.tags, <String>['pt', '仙逆']);
    expect(task.ratio, 2.5);
    expect(task.serverLabel, 'tracker.example');
    expect(task.addedAt, isNotNull);
    expect(task.progress, closeTo(0.5, 0.0001));
  });

  test('登录成功后可拉取任务，并复用会话（不再重复登录）', () async {
    final _FakeQb adapter = _FakeQb(<String, ResponseBody Function(RequestOptions)>{
      '/api/v2/auth/login': (RequestOptions options) =>
          _ok('Ok.', cookies: <String>['SID=abc; path=/']),
      '/api/v2/app/version': (RequestOptions options) => _ok('v5.0.3'),
      '/api/v2/torrents/info': (RequestOptions options) {
        return _json(<dynamic>[
          <String, dynamic>{'hash': 'h1', 'name': 'A', 'state': 'uploading', 'size': 10, 'completed': 10},
        ]);
      },
    });

    final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = adapter);
    final List<DownloaderTask> tasks =
        await client.fetchTasks(config, credential: <String, dynamic>{'password': 'secret'});
    expect(tasks.length, 1);
    expect(tasks.single.name, 'A');
    expect(tasks.single.state, TaskState.seeding);

    final RequestOptions loginRequest = adapter.requests
        .firstWhere((RequestOptions r) => r.uri.path == '/api/v2/auth/login');
    expect(loginRequest.method, 'POST');
    expect(loginRequest.contentType, Headers.formUrlEncodedContentType);
    final Map<String, String> loginBody =
        (loginRequest.data as Map<String, dynamic>).cast<String, String>();
    expect(loginBody['username'], 'admin');
    expect(loginBody['password'], 'secret');

    await client.fetchTasks(config, credential: <String, dynamic>{'password': 'secret'});
    expect(
      adapter.requests.where((RequestOptions r) => r.uri.path == '/api/v2/auth/login').length,
      1,
      reason: '同一会话内应复用 SID',
    );
  });

  test('缺少密码：给出「补录账号密码」的明确原因', () async {
    final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = _FakeQb(<String, ResponseBody Function(RequestOptions)>{}));
    expect(
      () => client.fetchTasks(config),
      throwsA(
        isA<DownloaderFetchException>().having(
          (DownloaderFetchException e) => e.kind,
          'kind',
          DownloaderFailureKind.missingCredential,
        ),
      ),
    );
  });

  test('密码错：提示检查 WebUI 账号密码；403：提示白名单/Host 校验', () async {
    final _FakeQb bad = _FakeQb(<String, ResponseBody Function(RequestOptions)>{
      '/api/v2/auth/login': (RequestOptions options) => _ok('Fails.'),
    });
    final QbittorrentClient client1 = QbittorrentClient(Dio()..httpClientAdapter = bad);
    expect(
      () => client1.fetchTasks(config, credential: <String, dynamic>{'password': 'x'}),
      throwsA(
        isA<DownloaderFetchException>()
            .having((DownloaderFetchException e) => e.kind, 'kind',
                DownloaderFailureKind.unauthorized)
            .having((DownloaderFetchException e) => e.message, 'message',
                contains('用户名与密码')),
      ),
    );

    final _FakeQb banned = _FakeQb(<String, ResponseBody Function(RequestOptions)>{
      '/api/v2/auth/login': (RequestOptions options) => ResponseBody.fromString('', 403),
    });
    final QbittorrentClient client2 = QbittorrentClient(Dio()..httpClientAdapter = banned);
    expect(
      () => client2.fetchTasks(config, credential: <String, dynamic>{'password': 'x'}),
      throwsA(
        isA<DownloaderFetchException>()
            .having((DownloaderFetchException e) => e.message, 'message',
                contains('Host header')),
      ),
    );
  });

  test('写操作使用 qBittorrent 规定的路径与参数', () async {
    final _FakeQb adapter = _FakeQb(<String, ResponseBody Function(RequestOptions)>{
      '/api/v2/auth/login': (RequestOptions options) => _ok('Ok.', cookies: <String>['SID=s1; path=/']),
      '/api/v2/app/version': (RequestOptions options) => _ok('v5.0.3'),
      '/api/v2/torrents/pause': (RequestOptions options) => _ok(''),
      '/api/v2/torrents/resume': (RequestOptions options) => _ok(''),
      '/api/v2/torrents/delete': (RequestOptions options) => _ok(''),
      '/api/v2/torrents/setCategory': (RequestOptions options) => _ok(''),
      '/api/v2/torrents/addTags': (RequestOptions options) => _ok(''),
      '/api/v2/torrents/removeTags': (RequestOptions options) => _ok(''),
      '/api/v2/torrents/setLocation': (RequestOptions options) => _ok(''),
    });
    final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = adapter);
    final Map<String, dynamic> credential = <String, dynamic>{'password': 'secret'};

    await client.pause(config, credential, <String>['h1', 'h2']);
    await client.resume(config, credential, <String>['h1']);
    await client.remove(config, credential, <String>['h1'], deleteFiles: true);
    await client.setCategory(config, credential, <String>['h1'], 'movie');
    await client.setTags(config, credential, <String>['h1'], <String>['pt', 'hd'], mode: 'add');
    await client.setTags(config, credential, <String>['h1'], <String>['pt'], mode: 'remove');
    await client.setTags(config, credential, <String>['h1'], <String>['pt'], mode: 'set');
    await client.setLocation(config, credential, <String>['h1'], '/downloads/PT');

    RequestOptions requestOf(String path) =>
        adapter.requests.firstWhere((RequestOptions r) => r.uri.path == path);

    final Map<String, String> pauseBody =
        (requestOf('/api/v2/torrents/pause').data as Map<String, dynamic>)
            .cast<String, String>();
    expect(pauseBody['hashes'], 'h1|h2');
    final Map<String, String> deleteBody =
        (requestOf('/api/v2/torrents/delete').data as Map<String, dynamic>)
            .cast<String, String>();
    expect(deleteBody['deleteFiles'], 'true');
    expect(
      adapter.requests
          .where((RequestOptions r) => r.uri.path == '/api/v2/torrents/removeTags')
          .length,
      2,
      reason: 'mode=set 时先清空原标签，再写入新标签',
    );
    final Map<String, String> addTagsBody =
        (requestOf('/api/v2/torrents/addTags').data as Map<String, dynamic>)
            .cast<String, String>();
    expect(addTagsBody['tags'], 'pt,hd');
    final Map<String, String> locationBody =
        (requestOf('/api/v2/torrents/setLocation').data as Map<String, dynamic>)
            .cast<String, String>();
    expect(locationBody['location'], '/downloads/PT');
  });

  test('任务列表结构异常时报「返回结构不符合预期」', () async {
    final _FakeQb adapter = _FakeQb(<String, ResponseBody Function(RequestOptions)>{
      '/api/v2/auth/login': (RequestOptions options) => _ok('Ok.', cookies: <String>['SID=s1; path=/']),
      '/api/v2/app/version': (RequestOptions options) => _ok('v5.0.3'),
      '/api/v2/torrents/info': (RequestOptions options) => _ok('<html>login</html>'),
    });
    final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = adapter);
    expect(
      () => client.fetchTasks(config, credential: <String, dynamic>{'password': 'secret'}),
      throwsA(
        isA<DownloaderFetchException>().having(
          (DownloaderFetchException e) => e.kind,
          'kind',
          DownloaderFailureKind.unparsed,
        ),
      ),
    );
  });
}