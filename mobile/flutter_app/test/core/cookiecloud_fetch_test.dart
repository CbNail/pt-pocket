// CookieCloud 拉取链路测试：候选地址（协议兜底 / 反代路径）、响应形态兼容、
// 失败归因，以及「拉取 + 解密」整条链路的端到端打通。
//
// 加密由测试自行实现，与官方 CryptoJS 口径一致：
// 口令 = md5(uuid-password) 前 16 位；EVP_BytesToKey(MD5) 派生 key/iv；
// AES-256-CBC + PKCS7；密文为 base64("Salted__" + salt + ciphertext)。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pt_pocket/core/services/cookiecloud_service.dart';

/// 按官方算法加密，供端到端用例使用。
String _encryptForTest({required String uuid, required String password, required String plain}) {
  final Random random = Random(20261104);
  final Uint8List salt = Uint8List.fromList(List<int>.generate(8, (_) => random.nextInt(256)));
  final ({Uint8List key, Uint8List iv}) derived = CookieCloudCrypto.evpBytesToKey(
    Uint8List.fromList(utf8.encode(CookieCloudCrypto.derivePassphrase(uuid, password))),
    salt,
  );
  final Uint8List raw = Uint8List.fromList(utf8.encode(plain));
  final int padCount = 16 - (raw.length % 16);
  final Uint8List padded = Uint8List(raw.length + padCount)..setAll(0, raw);
  for (int i = raw.length; i < padded.length; i++) {
    padded[i] = padCount;
  }
  final CBCBlockCipher cipher = CBCBlockCipher(AESEngine())
    ..init(true, ParametersWithIV<KeyParameter>(KeyParameter(derived.key), derived.iv));
  final Uint8List encrypted = Uint8List(padded.length);
  for (int offset = 0; offset < padded.length; offset += 16) {
    cipher.processBlock(padded, offset, encrypted, offset);
  }
  final BytesBuilder body = BytesBuilder(copy: false)
    ..add(utf8.encode('Salted__'))
    ..add(salt)
    ..add(encrypted);
  return base64Encode(body.toBytes());
}

/// 按请求地址脚本化响应的适配器，并记录实际发出的请求。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.respond);

  final (String body, int status) Function(Uri uri) respond;
  final List<Uri> requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final (String body, int status) = respond(options.uri);
    return ResponseBody.fromString(
      body,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 直接抛连接异常的适配器。
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
  const String uuid = 'a1b2c3d4e5f60718';

  group('候选请求地址', () {
    test('保留反代子路径与端口，官方路径优先', () {
      final List<Uri> candidates =
          CookieCloudService.buildGetUriCandidates('https://cc.example.com:8900/cc', 'u1');

      expect(candidates.first.toString(), 'https://cc.example.com:8900/cc/get/u1');
    });

    test('不写协议时：内网按 http、公网按 https，另一种协议自动兜底', () {
      final List<Uri> lan = CookieCloudService.buildGetUriCandidates('192.168.1.10:8088', 'u1');
      expect(lan.first.toString(), 'http://192.168.1.10:8088/get/u1');
      expect(lan[1].toString(), 'https://192.168.1.10:8088/get/u1');

      final List<Uri> wan = CookieCloudService.buildGetUriCandidates('cc.example.com:8900', 'u1');
      expect(wan.first.toString(), 'https://cc.example.com:8900/get/u1');
      expect(wan[1].toString(), 'http://cc.example.com:8900/get/u1');
    });

    test('附带 ?uuid= 形态，兼容反代改写路径的部署', () {
      final List<Uri> candidates =
          CookieCloudService.buildGetUriCandidates('https://cc.example.com', 'u9');

      expect(
        candidates.map((Uri uri) => uri.toString()),
        contains('https://cc.example.com/get?uuid=u9'),
      );
    });

    test('地址或 UUID 缺失时给出明确错误', () {
      expect(
        () => CookieCloudService.buildGetUriCandidates('', 'u'),
        throwsA(isA<CookieCloudException>()),
      );
      expect(
        () => CookieCloudService.buildGetUriCandidates('https://cc.example.com', '   '),
        throwsA(isA<CookieCloudException>()),
      );
    });
  });

  group('拉取响应形态', () {
    test('标准 {encrypted: ...} 响应', () async {
      final _ScriptedAdapter adapter =
          _ScriptedAdapter((Uri uri) => ('{"encrypted":"CIPHER","updated":123}', 200));
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final CookieCloudFetch fetched =
          await CookieCloudService(dio: dio).fetch(host: 'https://cc.example.com', uuid: 'u1');

      expect(fetched.encrypted, 'CIPHER');
      expect(fetched.uri.toString(), 'https://cc.example.com/get/u1');
      expect(adapter.requests.single.toString(), 'https://cc.example.com/get/u1');
    });

    test('密文被再包一层引号（JSON 字符串）也能取出', () async {
      final _ScriptedAdapter adapter =
          _ScriptedAdapter((Uri uri) => (jsonEncode('{"encrypted":"CIPHER-2"}'), 200));
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final CookieCloudFetch fetched =
          await CookieCloudService(dio: dio).fetch(host: 'https://cc.example.com', uuid: 'u1');

      expect(fetched.encrypted, 'CIPHER-2');
    });

    test('直接返回密文文本的部署也能识别', () async {
      final _ScriptedAdapter adapter =
          _ScriptedAdapter((Uri uri) => ('U2FsdGVkX1+RAW-CIPHER', 200));
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final CookieCloudFetch fetched =
          await CookieCloudService(dio: dio).fetch(host: 'https://cc.example.com', uuid: 'u1');

      expect(fetched.encrypted, 'U2FsdGVkX1+RAW-CIPHER');
    });

    test('首个候选 404 时自动尝试 ?uuid= 形态', () async {
      final _ScriptedAdapter adapter = _ScriptedAdapter((Uri uri) {
        if (uri.queryParameters.containsKey('uuid')) {
          return ('{"encrypted":"FALLBACK"}', 200);
        }
        return ('not found', 404);
      });
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final CookieCloudFetch fetched =
          await CookieCloudService(dio: dio).fetch(host: 'https://cc.example.com', uuid: 'u1');

      expect(fetched.encrypted, 'FALLBACK');
      expect(fetched.uri.queryParameters['uuid'], 'u1');
      expect(adapter.requests.length, greaterThan(1));
    });

    test('全部尝试失败时，错误信息带上每条尝试的地址与状态', () async {
      final _ScriptedAdapter adapter = _ScriptedAdapter((Uri uri) => ('boom', 500));
      final Dio dio = Dio()..httpClientAdapter = adapter;

      await expectLater(
        CookieCloudService(dio: dio).fetch(host: 'https://cc.example.com', uuid: 'u1'),
        throwsA(
          isA<CookieCloudException>().having(
            (CookieCloudException e) => e.message,
            'message',
            allOf(contains('HTTP 500'), contains('/get/u1')),
          ),
        ),
      );
    });

    test('域名解析失败时给出归因，而不是只有一句“失败”', () async {
      final Dio dio = Dio()..httpClientAdapter = _UnreachableAdapter();

      await expectLater(
        CookieCloudService(dio: dio).fetch(host: 'https://cc.example.com', uuid: 'u1'),
        throwsA(
          isA<CookieCloudException>().having(
            (CookieCloudException e) => e.message,
            'message',
            contains('无法建立连接'),
          ),
        ),
      );
    });
  });

  group('端到端：拉取 + 解密', () {
    test('官方算法密文经拉取后能解析出 Cookie', () async {
      const String password = 'my-cc-password';
      const String plain =
          '{"cookie_data":{"m-team.example":[{"name":"sid","value":"abc"},'
          '{"name":"tok","value":"def"}]},"local_storage_data":{}}';
      final String encrypted = _encryptForTest(uuid: uuid, password: password, plain: plain);
      final _ScriptedAdapter adapter =
          _ScriptedAdapter((Uri uri) => (jsonEncode(<String, String>{'encrypted': encrypted}), 200));
      final Dio dio = Dio()..httpClientAdapter = adapter;

      final CookieCloudImport imported = await CookieCloudService(dio: dio).fetchAndImport(
        host: '192.168.1.10:8088',
        uuid: uuid,
        password: password,
      );

      expect(imported.uri.toString(), 'http://192.168.1.10:8088/get/$uuid');
      expect(imported.bundle.domainCount, 1);
      expect(imported.bundle.cookieCount, 2);
      expect(imported.bundle.cookieHeaderForHost('m-team.example'), 'sid=abc; tok=def');
    });
  });
}