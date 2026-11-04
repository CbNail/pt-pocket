// 地址归一化 / 拼接，以及健康探测归因的单元测试。
//
// 覆盖本轮修复的核心回归点：反代“域名+端口+子路径”不能被丢掉，
// 且「地址可达但后端未就绪」必须与「网络不可达」区分开。

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/network/url_utils.dart';

import '../helpers/recording_adapter.dart';

/// 返回任意文本与状态码的适配器（用来说明“200 但不是本服务”的情况）。
class _TextAdapter implements HttpClientAdapter {
  _TextAdapter(this.body, this.statusCode);

  final String body;
  final int statusCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 模拟域名解析失败 / 端口不通。
class _UnreachableAdapter implements HttpClientAdapter {
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

void main() {
  group('UrlUtils.normalize', () {
    test('内网 IP + 端口：补 http 并保留端口', () {
      expect(
        UrlUtils.normalize('192.168.5.206:45005')?.toString(),
        'http://192.168.5.206:45005',
      );
    });

    test('公网域名 + 反代端口：补 https 并保留端口', () {
      expect(
        UrlUtils.normalize('pt.example.xyz:5888')?.toString(),
        'https://pt.example.xyz:5888',
      );
    });

    test('保留反代子路径并去掉末尾斜杠', () {
      expect(
        UrlUtils.normalize('https://pt.example.xyz:5888/ptp/')?.toString(),
        'https://pt.example.xyz:5888/ptp',
      );
    });

    test('丢弃 query 与 fragment，避免拼接 API 路径时被截断', () {
      expect(
        UrlUtils.normalize('https://pt.example.xyz:5888/ptp?x=1#f')?.toString(),
        'https://pt.example.xyz:5888/ptp',
      );
    });

    test('内网域名后缀与非 http(s) 协议的判定', () {
      expect(UrlUtils.normalize('nas.local:8000')?.toString(), 'http://nas.local:8000');
      expect(UrlUtils.normalize('ftp://nas.local'), isNull);
      expect(UrlUtils.normalize('   '), isNull);
    });
  });

  group('UrlUtils.joinPath', () {
    test('无子路径时直接拼接', () {
      expect(
        UrlUtils.joinPath(Uri.parse('https://h:5888'), '/api/v1/health').toString(),
        'https://h:5888/api/v1/health',
      );
    });

    test('反代挂在子路径下时必须保留子路径', () {
      expect(
        UrlUtils.joinPath(Uri.parse('https://h:5888/ptp'), '/api/v1/health').toString(),
        'https://h:5888/ptp/api/v1/health',
      );
    });

    test('内网 http 地址保留端口', () {
      expect(
        UrlUtils.joinPath(Uri.parse('http://192.168.5.206:45005'), '/api/v1/health').toString(),
        'http://192.168.5.206:45005/api/v1/health',
      );
    });
  });

  group('HttpHealthProbe.diagnose', () {
    test('200 + JSON：可用，且请求地址带着反代子路径', () async {
      final RecordingAdapter adapter = RecordingAdapter(<String, dynamic>{'status': 'ok'});
      final Dio dio = Dio()..httpClientAdapter = adapter;
      final HttpHealthProbe probe = HttpHealthProbe(dio: dio);

      final HealthProbeResult result =
          await probe.diagnose(Uri.parse('https://h:5888/ptp'), const Duration(seconds: 2));

      expect(result.reachable, isTrue);
      expect(result.apiHealthy, isTrue);
      expect(result.looksLikeApi, isTrue);
      expect(result.isUsable, isTrue);
      // 诊断与选路两次探测都必须带住反代子路径。
      expect(await probe.call(Uri.parse('https://h:5888/ptp'), const Duration(seconds: 2)), isTrue);
      expect(adapter.requests, isNotEmpty);
      for (final RequestOptions request in adapter.requests) {
        expect(request.uri.toString(), 'https://h:5888/ptp/api/v1/health');
      }
    });

    test('200 + HTML：地址可达但不是本服务，不能用于选路', () async {
      final Dio dio = Dio()..httpClientAdapter = _TextAdapter('<html>login</html>', 200);
      final HttpHealthProbe probe = HttpHealthProbe(dio: dio);
      final Uri target = Uri.parse('http://192.168.5.206:45005');

      final HealthProbeResult result = await probe.diagnose(target, const Duration(seconds: 2));

      expect(result.reachable, isTrue);
      expect(result.looksLikeApi, isFalse);
      expect(result.message, contains('可能反代到了其它服务'));
      expect(await probe.call(target, const Duration(seconds: 2)), isFalse);
    });

    test('404：地址可达、后端未就绪，不能被显示成网络不可达', () async {
      final Dio dio = Dio()..httpClientAdapter = _TextAdapter('not found', 404);
      final HttpHealthProbe probe = HttpHealthProbe(dio: dio);

      final HealthProbeResult result = await probe
          .diagnose(Uri.parse('http://192.168.5.206:45005'), const Duration(seconds: 2));

      expect(result.reachable, isTrue);
      expect(result.apiHealthy, isFalse);
      expect(result.reachableButNotReady, isTrue);
      expect(result.statusCode, 404);
      expect(result.message, contains('HTTP 404'));
    });

    test('域名解析失败：不可达并给出归因', () async {
      final Dio dio = Dio()..httpClientAdapter = _UnreachableAdapter();
      final HttpHealthProbe probe = HttpHealthProbe(dio: dio);

      final HealthProbeResult result = await probe
          .diagnose(Uri.parse('https://pt.example.xyz:5888'), const Duration(seconds: 2));

      expect(result.reachable, isFalse);
      expect(result.apiHealthy, isFalse);
      expect(result.errorType, 'dns');
      expect(result.message, contains('域名解析失败或端口未开放'));
    });
  });
}