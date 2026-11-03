// CookieCloud 导入测试：官方算法自加密/解密往返、结构解析、域名匹配与错误提示。
//
// 加密由测试自行实现（与官方 CryptoJS 口径一致）：
// 口令 = md5(uuid-password) 前 16 位，EVP_BytesToKey(MD5) 派生 key/iv，
// AES-256-CBC + PKCS7，密文为 base64("Salted__" + salt + ciphertext)。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pt_pocket/core/services/cookiecloud_service.dart';

/// 测试用加密实现。
String encryptForTest({required String uuid, required String password, required String plain}) {
  final Random random = Random(20261103);
  final Uint8List salt = Uint8List.fromList(
    List<int>.generate(8, (_) => random.nextInt(256)),
  );
  final ({Uint8List key, Uint8List iv}) derived = CookieCloudCrypto.evpBytesToKey(
    Uint8List.fromList(utf8.encode(CookieCloudCrypto.derivePassphrase(uuid, password))),
    salt,
  );

  final Uint8List raw = Uint8List.fromList(utf8.encode(plain));
  final int padCount = 16 - (raw.length % 16);
  final Uint8List padded = Uint8List(raw.length + padCount)
    ..setAll(0, raw);
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

void main() {
  const String uuid = 'a1b2c3d4e5f60718';
  const String password = 'my-cc-password';

  test('派生口令为 md5(uuid-password) 前 16 位', () {
    final String passphrase = CookieCloudCrypto.derivePassphrase(uuid, password);
    expect(passphrase, hasLength(16));
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(passphrase), isTrue);
  });

  test('可以解密按官方算法加密的密文', () {
    const String plain = '{"cookie_data":{"a.example":[{"name":"sid","value":"1"}]},'
        '"local_storage_data":{}}';
    final String encrypted = encryptForTest(uuid: uuid, password: password, plain: plain);

    final String decrypted = CookieCloudCrypto.decryptToString(
      uuid: uuid,
      password: password,
      encrypted: encrypted,
    );
    expect(decrypted, plain);
  });

  test('UUID 或密码不正确时抛出明确错误', () {
    final String encrypted = encryptForTest(uuid: uuid, password: password, plain: '{"cookie_data":{}}');

    expect(
      () => CookieCloudCrypto.decryptToString(uuid: uuid, password: 'wrong', encrypted: encrypted),
      throwsA(isA<CookieCloudException>()),
    );
  });

  test('非 Salted__ 密文提示固定 IV 变体，不做猜测解密', () {
    final String unsupported = base64Encode(Uint8List(32));

    expect(
      () => CookieCloudCrypto.decryptToString(uuid: uuid, password: password, encrypted: unsupported),
      throwsA(
        isA<CookieCloudException>().having(
          (CookieCloudException e) => e.message,
          'message',
          contains('固定 IV'),
        ),
      ),
    );
  });

  test('base64 非法时给出提示', () {
    expect(
      () => CookieCloudCrypto.decryptToString(uuid: uuid, password: password, encrypted: 'not base64!!'),
      throwsA(isA<CookieCloudException>()),
    );
  });

  test('解析结果兼容 cookie_data 结构与早期扁平结构', () {
    final CookieCloudBundle modern = CookieCloudBundle.parse(<String, dynamic>{
      'cookie_data': <String, dynamic>{
        'a.example': <dynamic>[
          <String, dynamic>{'name': 'sid', 'value': '1', 'domain': '.a.example'},
        ],
      },
      'local_storage_data': <String, dynamic>{},
    });
    expect(modern.domainCount, 1);
    expect(modern.cookieCount, 1);

    final CookieCloudBundle legacy = CookieCloudBundle.parse(<String, dynamic>{
      'a.example': <dynamic>[
        <String, dynamic>{'name': 'sid', 'value': '1'},
        <String, dynamic>{'name': 'tok', 'value': '2'},
      ],
    });
    expect(legacy.cookieCount, 2);
  });

  test('按主机名匹配 Cookie 支持精确与子域', () {
    final CookieCloudBundle bundle = CookieCloudBundle.parse(<String, dynamic>{
      'cookie_data': <String, dynamic>{
        '.example.com': <dynamic>[
          <String, dynamic>{'name': 'sid', 'value': '1'},
        ],
        'other.net': <dynamic>[
          <String, dynamic>{'name': 'x', 'value': '9'},
        ],
      },
    });

    expect(bundle.cookiesForHost('pt.example.com'), hasLength(1));
    expect(bundle.cookiesForHost('example.com'), hasLength(1));
    expect(bundle.cookiesForHost('pt.other.net'), hasLength(1));
    expect(bundle.cookiesForHost('unknown.org'), isEmpty);
    expect(bundle.cookieHeaderForHost('pt.example.com'), 'sid=1');
  });

  test('buildGetUri 规范化服务器地址', () {
    expect(
      CookieCloudService.buildGetUri('https://ccc.example.com/', uuid).toString(),
      'https://ccc.example.com/get/$uuid',
    );
    expect(
      () => CookieCloudService.buildGetUri('not a host', uuid),
      throwsA(isA<CookieCloudException>()),
    );
  });
}