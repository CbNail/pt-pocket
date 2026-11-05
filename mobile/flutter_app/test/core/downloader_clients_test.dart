// 下载器直连客户端能力测试：
// - qBittorrent：添加种子（链接 / 文件）、重新汇报、重新校验、强制继续、单任务限速；
// - Transmission：409 会话握手、任务字段映射、传输概览、添加种子（链接 / metainfo）、
//   暂停 / 删除 / 改路径 / 标签 / 校验 / 汇报 / 强制开始 / 限速；
// - 能力边界：Transmission 没有「分类」→ 明确报「该下载器不支持」，不静默写标签冒充成功。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/direct/qbittorrent_client.dart';
import 'package:pt_pocket/core/direct/transmission_client.dart';
import 'package:pt_pocket/core/models/downloader.dart';

class _Fake implements HttpClientAdapter {
  _Fake(this.respond);

  final ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object payload, {int status = 200, Map<String, List<String>>? headers}) =>
    ResponseBody.fromString(
      jsonEncode(payload),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        ...?headers,
      },
    );

ResponseBody _text(String body) => ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{Headers.contentTypeHeader: <String>['text/plain']},
    );

const DownloaderConfig _qb = DownloaderConfig(
  id: 'qb-1',
  name: 'qb',
  kind: DownloaderKind.qbittorrent,
  baseUrl: 'http://127.0.0.1:8080',
  username: 'admin',
);

const DownloaderConfig _tr = DownloaderConfig(
  id: 'tr-1',
  name: 'tr',
  kind: DownloaderKind.transmission,
  baseUrl: 'http://127.0.0.1:9091',
  username: 'admin',
);

/// qBittorrent 假后端：登录成功 + 按路径回 Ok。
_Fake _qbAdapter({ResponseBody Function(RequestOptions options)? override}) => _Fake(
      (RequestOptions options) {
        if (options.uri.path == '/api/v2/auth/login') {
          return ResponseBody.fromString(
            'Ok.',
            200,
            headers: <String, List<String>>{'set-cookie': <String>['SID=abc123; path=/']},
          );
        }
        final ResponseBody? custom = override?.call(options);
        if (custom != null) return custom;
        return _text('');
      },
    );

/// Transmission 假后端：首次返回 409（带会话 id），之后按 method 分发。
_Fake _trAdapter({
  Map<String, dynamic> torrents = const <String, dynamic>{},
  List<Map<String, dynamic>> torrentList = const <Map<String, dynamic>>[],
}) {
  int calls = 0;
  return _Fake((RequestOptions options) {
    calls++;
    if (calls == 1) {
      return ResponseBody.fromString(
        '',
        409,
        headers: <String, List<String>>{
          'x-transmission-session-id': <String>['sess-1'],
        },
      );
    }
    final Map<String, dynamic> body = jsonDecode(options.data as String) as Map<String, dynamic>;
    final String method = body['method'] as String;
    final Map<String, dynamic> arguments =
        (body['arguments'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return _json(<String, dynamic>{
      'result': 'success',
      'arguments': switch (method) {
        'torrent-get' => <String, dynamic>{
            'torrents': (arguments['ids'] is List)
                ? torrentList
                : (torrentList.isNotEmpty ? torrentList : <dynamic>[torrents]),
          },
        'session-stats' => <String, dynamic>{
            'downloadSpeed': 4096,
            'uploadSpeed': 1024,
            'downloadedBytes': 100,
            'uploadedBytes': 200,
          },
        'session-get' => <String, dynamic>{
            'version': '4.0.5',
            'download-dir': '/downloads',
            'speed-limit-down-enabled': true,
            'speed-limit-down': 1024,
            'speed-limit-up-enabled': false,
            'speed-limit-up': 0,
          },
        'free-space' => <String, dynamic>{'size-bytes': 987654321},
        _ => <String, dynamic>{},
      },
    });
  });
}

void main() {
  group('qBittorrent 写操作与添加种子', () {
    test('添加种子：链接按换行拼接，分类 / 标签 / 路径 / 暂停一起下发', () async {
      final _Fake adapter = _qbAdapter();
      final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = adapter);

      await client.addTorrentLinks(
        _qb,
        <String, dynamic>{'password': 'pw'},
        links: <String>[' magnet:?xt=urn:btih:aaa ', 'magnet:?xt=urn:btih:bbb', ''],
        category: 'pterclub',
        tags: <String>['官种'],
        savePath: '/downloads/pt',
        paused: true,
      );

      final RequestOptions add = adapter.requests
          .firstWhere((RequestOptions r) => r.uri.path == '/api/v2/torrents/add');
      final Map<String, dynamic> body = (add.data as Map<String, dynamic>);
      expect(add.method, 'POST');
      expect(body['urls'], 'magnet:?xt=urn:btih:aaa\nmagnet:?xt=urn:btih:bbb');
      expect(body['category'], 'pterclub');
      expect(body['tags'], '官种');
      expect(body['savepath'], '/downloads/pt');
      expect(body['paused'], 'true');
    });

    test('添加种子：没有任何有效链接时直接报错，不发请求', () async {
      final _Fake adapter = _qbAdapter();
      final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = adapter);

      await expectLater(
        client.addTorrentLinks(_qb, <String, dynamic>{'password': 'pw'}, links: <String>['', '  ']),
        throwsA(isA<DownloaderFetchException>()),
      );
      expect(
        adapter.requests.any((RequestOptions r) => r.uri.path == '/api/v2/torrents/add'),
        isFalse,
      );
    });

    test('添加种子文件走 multipart（字段名 torrents）', () async {
      final _Fake adapter = _qbAdapter();
      final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = adapter);

      await client.addTorrentFile(
        _qb,
        <String, dynamic>{'password': 'pw'},
        bytes: <int>[1, 2, 3],
        filename: 'demo.torrent',
        category: 'pt',
        paused: false,
      );

      final RequestOptions add = adapter.requests
          .firstWhere((RequestOptions r) => r.uri.path == '/api/v2/torrents/add');
      expect(add.data, isA<FormData>());
      final FormData form = add.data as FormData;
      expect(form.files.single.key, 'torrents');
      expect(form.files.single.value.filename, 'demo.torrent');
      expect(form.fields.firstWhere((MapEntry<String, String> f) => f.key == 'paused').value, 'false');
    });

    test('重新汇报 / 重新校验 / 强制继续 / 单任务限速的路径与参数', () async {
      final _Fake adapter = _qbAdapter();
      final QbittorrentClient client = QbittorrentClient(Dio()..httpClientAdapter = adapter);

      await client.recheck(_qb, <String, dynamic>{'password': 'pw'}, <String>['h1', 'h2']);
      await client.reannounce(_qb, <String, dynamic>{'password': 'pw'}, <String>['h1']);
      await client.setForceStart(_qb, <String, dynamic>{'password': 'pw'}, <String>['h1'], true);
      await client.setDownloadLimit(
        _qb,
        <String, dynamic>{'password': 'pw'},
        <String>['h1'],
        1048576,
      );

      Map<String, dynamic> bodyOf(String path) => adapter.requests
          .firstWhere((RequestOptions r) => r.uri.path == path)
          .data as Map<String, dynamic>;

      expect(bodyOf('/api/v2/torrents/recheck')['hashes'], 'h1|h2');
      expect(bodyOf('/api/v2/torrents/reannounce')['hashes'], 'h1');
      expect(bodyOf('/api/v2/torrents/setForceStart')['value'], 'true');
      expect(bodyOf('/api/v2/torrents/setDownloadLimit')['limit'], '1048576');
    });
  });

  group('Transmission 直连', () {
    test('409 会话握手后带会话 id 重试，任务字段按统一模型映射', () async {
      final _Fake adapter = _trAdapter(
        torrents: <String, dynamic>{
          'id': 7,
          'hashString': 'ABCDEF',
          'name': '任务甲',
          'totalSize': 1000,
          'leftUntilDone': 400,
          'percentDone': 0.6,
          'status': 4,
          'rateDownload': 2048,
          'rateUpload': 1024,
          'eta': 600,
          'downloadDir': '/downloads/pt',
          'labels': <String>['pt', '官种'],
          'addedDate': 1767225600,
          'uploadRatio': 1.5,
          'trackers': <dynamic>[
            <String, dynamic>{'announce': 'https://tracker.a.com/announce'},
          ],
          'magnetLink': 'magnet:?xt=urn:btih:ABCDEF',
          'downloadLimited': true,
          'downloadLimit': 512,
          'uploadLimited': false,
          'uploadLimit': 0,
        },
      );
      final TransmissionClient client = TransmissionClient(Dio()..httpClientAdapter = adapter);

      final List<DownloaderTask> tasks = await client.fetchTasks(
        _tr,
        credential: <String, dynamic>{'password': 'pw'},
      );

      expect(tasks, hasLength(1));
      final DownloaderTask task = tasks.single;
      expect(task.hash, 'ABCDEF');
      expect(task.name, '任务甲');
      expect(task.state, TaskState.downloading);
      expect(task.sizeBytes, 1000);
      expect(task.completedBytes, 600);
      expect(task.savePath, '/downloads/pt');
      expect(task.tags, <String>['pt', '官种']);
      // Transmission 没有分类：不能把第一个标签当分类。
      expect(task.category, isEmpty);
      expect(task.magnetUri, 'magnet:?xt=urn:btih:ABCDEF');
      expect(task.downloadLimitBytes, 512 * 1024);
      expect(task.uploadLimitBytes, 0);
      expect(task.tracker, 'https://tracker.a.com/announce');
      expect(task.addedAt, isNotNull);

      // 第一次 409（无会话 id），第二次带上服务端下发的会话 id。
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.last.headers['X-Transmission-Session-Id'], 'sess-1');
      expect(
        adapter.requests.last.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('admin:pw'))}',
      );
    });

    test('传输概览：速率 / 版本 / 剩余空间 / 全局限速', () async {
      final _Fake adapter = _trAdapter();
      final TransmissionClient client = TransmissionClient(Dio()..httpClientAdapter = adapter);

      final QbTransferInfo info = await client.fetchTransferInfo(
        _tr,
        credential: <String, dynamic>{'password': 'pw'},
      );

      expect(info.downloadSpeed, 4096);
      expect(info.uploadSpeed, 1024);
      expect(info.downloadedBytes, 100);
      expect(info.uploadedBytes, 200);
      expect(info.version, '4.0.5');
      expect(info.freeSpaceBytes, 987654321);
      // 会话级下载限速 1024 KB/s，上传限速未启用 → 0 表示不限。
      expect(info.downloadLimitBytes, 1024 * 1024);
      expect(info.uploadLimitBytes, 0);
    });

    test('添加种子：链接逐条提交，带标签 / 路径 / 暂停', () async {
      final _Fake adapter = _trAdapter();
      final TransmissionClient client = TransmissionClient(Dio()..httpClientAdapter = adapter);

      await client.addTorrentLinks(
        _tr,
        <String, dynamic>{'password': 'pw'},
        links: <String>['magnet:?xt=urn:btih:aaa', 'https://x.test/a.torrent'],
        tags: <String>['pt'],
        savePath: '/downloads/pt',
        paused: true,
      );

      final List<Map<String, dynamic>> adds = adapter.requests
          .map((RequestOptions r) => jsonDecode(r.data as String) as Map<String, dynamic>)
          .where((Map<String, dynamic> b) => b['method'] == 'torrent-add')
          .toList();
      // 首次请求要先过一次 409 会话握手，所以第一条链接会记录两次：按去重后的链接断言。
      final List<String> filenames = adds
          .map((Map<String, dynamic> b) =>
              (b['arguments'] as Map<String, dynamic>)['filename'] as String)
          .toSet()
          .toList()
        ..sort();
      expect(filenames, <String>['https://x.test/a.torrent', 'magnet:?xt=urn:btih:aaa']);
      expect((adds.first['arguments'] as Map<String, dynamic>)['filename'], 'magnet:?xt=urn:btih:aaa');
      expect((adds.first['arguments'] as Map<String, dynamic>)['labels'], <String>['pt']);
      expect((adds.first['arguments'] as Map<String, dynamic>)['download-dir'], '/downloads/pt');
      expect((adds.first['arguments'] as Map<String, dynamic>)['paused'], true);
    });

    test('添加种子文件走 metainfo（base64）', () async {
      final _Fake adapter = _trAdapter();
      final TransmissionClient client = TransmissionClient(Dio()..httpClientAdapter = adapter);

      await client.addTorrentFile(
        _tr,
        <String, dynamic>{'password': 'pw'},
        bytes: <int>[1, 2, 3],
        filename: 'demo.torrent',
      );

      final Map<String, dynamic> body = adapter.requests
          .map((RequestOptions r) => jsonDecode(r.data as String) as Map<String, dynamic>)
          .firstWhere((Map<String, dynamic> b) => b['method'] == 'torrent-add');
      expect((body['arguments'] as Map<String, dynamic>)['metainfo'], base64Encode(<int>[1, 2, 3]));
    });

    test('任务操作的方法名与参数', () async {
      final _Fake adapter = _trAdapter();
      final TransmissionClient client = TransmissionClient(Dio()..httpClientAdapter = adapter);
      final Map<String, dynamic> credential = <String, dynamic>{'password': 'pw'};

      await client.pause(_tr, credential, <String>['H1']);
      await client.resume(_tr, credential, <String>['H1']);
      await client.startNow(_tr, credential, <String>['H1']);
      await client.recheck(_tr, credential, <String>['H1']);
      await client.reannounce(_tr, credential, <String>['H1']);
      await client.setLocation(_tr, credential, <String>['H1'], '/downloads/new');
      await client.setAutoManaged(_tr, credential, <String>['H1'], true);
      await client.setDownloadLimit(_tr, credential, <String>['H1'], 1024 * 1024);
      await client.remove(_tr, credential, <String>['H1'], deleteFiles: true);

      final List<Map<String, dynamic>> bodies = adapter.requests
          .map((RequestOptions r) => jsonDecode(r.data as String) as Map<String, dynamic>)
          .toList();
      final List<String> methods =
          bodies.map((Map<String, dynamic> b) => b['method'] as String).toList();
      expect(
        methods,
        containsAll(<String>[
          'torrent-stop',
          'torrent-start',
          'torrent-start-now',
          'torrent-verify',
          'torrent-reannounce',
          'torrent-set',
          'torrent-remove',
        ]),
      );
      final Map<String, dynamic> locationSet = bodies.firstWhere(
        (Map<String, dynamic> b) =>
            b['method'] == 'torrent-set' &&
            (b['arguments'] as Map<String, dynamic>).containsKey('location-move'),
      );
      expect((locationSet['arguments'] as Map<String, dynamic>)['location-move'], '/downloads/new');

      final Map<String, dynamic> limitSet = bodies.firstWhere(
        (Map<String, dynamic> b) =>
            b['method'] == 'torrent-set' &&
            (b['arguments'] as Map<String, dynamic>).containsKey('downloadLimited'),
      );
      // Transmission 以 KB/s 为单位。
      expect((limitSet['arguments'] as Map<String, dynamic>)['downloadLimit'], 1024);
      expect((limitSet['arguments'] as Map<String, dynamic>)['downloadLimited'], true);

      final Map<String, dynamic> removed = bodies.firstWhere(
        (Map<String, dynamic> b) => b['method'] == 'torrent-remove',
      );
      expect((removed['arguments'] as Map<String, dynamic>)['delete-local-data'], true);
    });

    test('标签追加会先取回当前标签再整组覆盖（不误删已有标签）', () async {
      final _Fake adapter = _trAdapter(
        torrentList: <Map<String, dynamic>>[
          <String, dynamic>{'hashString': 'H1', 'labels': <String>['pt']},
        ],
      );
      final TransmissionClient client = TransmissionClient(Dio()..httpClientAdapter = adapter);

      await client.setTags(
        _tr,
        <String, dynamic>{'password': 'pw'},
        <String>['H1'],
        <String>['官种'],
        mode: 'add',
      );

      final List<Map<String, dynamic>> bodies = adapter.requests
          .map((RequestOptions r) => jsonDecode(r.data as String) as Map<String, dynamic>)
          .toList();
      expect(bodies.first['method'], 'torrent-get');
      final Map<String, dynamic> setBody = bodies
          .firstWhere((Map<String, dynamic> b) => b['method'] == 'torrent-set');
      expect((setBody['arguments'] as Map<String, dynamic>)['labels'], <String>['pt', '官种']);
    });

    test('分类不支持：明确报「该下载器不支持」，不写标签冒充', () async {
      final _Fake adapter = _trAdapter();
      final TransmissionClient client = TransmissionClient(Dio()..httpClientAdapter = adapter);

      await expectLater(
        client.setCategory(_tr, <String, dynamic>{'password': 'pw'}, <String>['H1'], 'pt'),
        throwsA(
          isA<DownloaderFetchException>().having(
            (DownloaderFetchException e) => e.message,
            'message',
            contains('该下载器不支持'),
          ),
        ),
      );
      expect(
        adapter.requests.any((RequestOptions r) => (r.data as String).contains('torrent-set')),
        isFalse,
      );
    });
  });
}