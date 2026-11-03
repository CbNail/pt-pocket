// 测试用记录型 HttpClientAdapter：拦截 dio 请求、记录 RequestOptions，
// 并返回预置的 JSON 响应体，不产生真实网络访问。
//
// 文件名不以 _test.dart 结尾，测试运行器不会把它当作测试用例执行。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter(this.payload, {this.statusCode = 200});

  /// 响应体（会被 JSON 编码）。
  Object? payload;

  int statusCode;

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
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}