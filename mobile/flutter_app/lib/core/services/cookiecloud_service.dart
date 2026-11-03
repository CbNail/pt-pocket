import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/md5.dart';

import '../config/app_config.dart';

/// CookieCloud 导入相关异常。
class CookieCloudException implements Exception {
  const CookieCloudException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 单条 Cookie。
class CookieCloudCookie {
  const CookieCloudCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
  });

  final String name;
  final String value;
  final String? domain;
  final String? path;

  String get pair => '$name=$value';
}

/// 解密后的 CookieCloud 数据。
class CookieCloudBundle {
  const CookieCloudBundle({required this.byDomain, required this.domainKeys});

  /// 域名 → Cookie 列表。
  final Map<String, List<CookieCloudCookie>> byDomain;

  /// 原始域名键（保留前导点等原始形态，便于排障）。
  final List<String> domainKeys;

  int get cookieCount =>
      byDomain.values.fold(0, (int sum, List<CookieCloudCookie> list) => sum + list.length);

  int get domainCount => byDomain.length;

  /// 取某主机名可用的 Cookie：精确匹配或子域匹配。
  List<CookieCloudCookie> cookiesForHost(String host) {
    final String target = host.toLowerCase();
    if (target.isEmpty) return const <CookieCloudCookie>[];
    final List<CookieCloudCookie> matched = <CookieCloudCookie>[];
    byDomain.forEach((String domain, List<CookieCloudCookie> list) {
      final String candidate = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      if (candidate.isEmpty) return;
      if (target == candidate || target.endsWith('.$candidate')) {
        matched.addAll(list);
      }
    });
    return matched;
  }

  /// 拼接为站点可直接使用的 Cookie 请求头。
  String cookieHeaderForHost(String host) =>
      cookiesForHost(host).map((CookieCloudCookie c) => c.pair).join('; ');

  /// 解析解密后的数据结构。
  ///
  /// 兼容两种形态：
  /// - 插件 0.1.5+：`{ cookie_data: { domain: [cookie...] }, local_storage_data: {...} }`
  /// - 早期版本：直接是 `{ domain: [cookie...] }`
  factory CookieCloudBundle.parse(Map<String, dynamic> decoded) {
    final Object? cookieData = decoded['cookie_data'] ?? decoded;
    final Map<String, List<CookieCloudCookie>> byDomain = <String, List<CookieCloudCookie>>{};
    final List<String> keys = <String>[];

    if (cookieData is Map) {
      cookieData.forEach((Object? domain, Object? cookies) {
        if (cookies is! List) return;
        final String key = domain?.toString() ?? '';
        keys.add(key);
        final List<CookieCloudCookie> list = byDomain.putIfAbsent(key, () => <CookieCloudCookie>[]);
        for (final Object? item in cookies) {
          if (item is! Map) continue;
          final Object? name = item['name'];
          if (name is! String || name.isEmpty) continue;
          list.add(
            CookieCloudCookie(
              name: name,
              value: item['value']?.toString() ?? '',
              domain: item['domain']?.toString(),
              path: item['path']?.toString(),
            ),
          );
        }
      });
    }

    return CookieCloudBundle(byDomain: byDomain, domainKeys: keys);
  }
}

/// CookieCloud 端到端加解密：官方算法。
///
/// 1. 口令 = `md5(uuid + '-' + password)` 的十六进制串前 16 位；
/// 2. 密文为 OpenSSL 兼容格式：base64("Salted__" + 8 字节 salt + 密文)，
///    key/iv 由 EVP_BytesToKey（MD5，key 32 字节 / iv 16 字节）派生；
/// 3. 解密使用 AES-256-CBC + PKCS7 填充。
///
/// 说明：0.3.0 起的 wxt 版本支持固定 IV 的新算法；若服务端返回的密文不是
/// `Salted__` 结构，这里会给出明确提示而不是猜测解密方式。
abstract final class CookieCloudCrypto {
  static const int _keyLen = 32;
  static const int _ivLen = 16;
  static const int _blockSize = 16;

  /// 由 uuid 与密码派生 CryptoJS 口令。
  static String derivePassphrase(String uuid, String password) {
    final Uint8List digest = MD5Digest().process(
      Uint8List.fromList(utf8.encode('$uuid-$password')),
    );
    return _hex(digest).substring(0, 16);
  }

  /// OpenSSL EVP_BytesToKey（MD5 版本）。
  static ({Uint8List key, Uint8List iv}) evpBytesToKey(Uint8List password, Uint8List salt) {
    final BytesBuilder material = BytesBuilder(copy: false);
    Uint8List lastHash = Uint8List(0);
    while (material.length < _keyLen + _ivLen) {
      final BytesBuilder input = BytesBuilder(copy: false)
        ..add(lastHash)
        ..add(password)
        ..add(salt);
      lastHash = MD5Digest().process(input.toBytes());
      material.add(lastHash);
    }
    final Uint8List bytes = material.toBytes();
    return (
      key: Uint8List.sublistView(bytes, 0, _keyLen),
      iv: Uint8List.sublistView(bytes, _keyLen, _keyLen + _ivLen),
    );
  }

  /// 解密为明文字符串；失败时抛出 [CookieCloudException]。
  static String decryptToString({
    required String uuid,
    required String password,
    required String encrypted,
  }) {
    final Uint8List raw;
    try {
      raw = base64Decode(encrypted.trim());
    } on FormatException {
      throw const CookieCloudException('密文不是合法的 Base64 内容');
    }
    if (raw.length <= 16 || raw.length % _blockSize != 0) {
      throw const CookieCloudException('密文长度不符合 AES 分块要求');
    }
    if (String.fromCharCodes(raw.sublist(0, 8)) != 'Salted__') {
      throw const CookieCloudException(
        '密文不是 OpenSSL("Salted__") 结构；若服务端为 0.3.0+ 的固定 IV 算法，需要另行适配',
      );
    }

    final Uint8List salt = Uint8List.sublistView(raw, 8, 16);
    final Uint8List cipherText = Uint8List.sublistView(raw, 16);
    final ({Uint8List key, Uint8List iv}) derived = evpBytesToKey(
      Uint8List.fromList(utf8.encode(derivePassphrase(uuid, password))),
      salt,
    );

    final CBCBlockCipher cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV<KeyParameter>(KeyParameter(derived.key), derived.iv));

    final Uint8List plain = Uint8List(cipherText.length);
    for (int offset = 0; offset < cipherText.length; offset += _blockSize) {
      cipher.processBlock(cipherText, offset, plain, offset);
    }

    final int padded = plain.length - _stripPkcs7(plain);
    try {
      // 严格按 UTF-8 解码：解密数据是 JSON，非法字节序列说明口令不对。
      return utf8.decode(Uint8List.sublistView(plain, 0, padded));
    } on FormatException {
      throw const CookieCloudException('解密失败：UUID 或密码不正确');
    }
  }

  /// 去掉 PKCS7 填充，返回需要裁剪的字节数。
  static int _stripPkcs7(Uint8List data) {
    if (data.isEmpty) throw const CookieCloudException('解密结果为空');
    final int pad = data.last;
    if (pad < 1 || pad > _blockSize) {
      throw const CookieCloudException('解密失败：UUID 或密码不正确');
    }
    for (int i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) {
        throw const CookieCloudException('解密失败：UUID 或密码不正确');
      }
    }
    return pad;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// CookieCloud 服务：拉取密文并在本机解密（端到端加密，口令不经服务端）。
class CookieCloudService {
  CookieCloudService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 构造 `GET {host}/get/{uuid}` 目标地址。
  static Uri buildGetUri(String host, String uuid) {
    final String base = host.trim().replaceAll(RegExp(r'/+$'), '');
    final Uri? uri = Uri.tryParse('$base/get/${uuid.trim()}');
    if (uri == null || uri.host.isEmpty) {
      throw const CookieCloudException('CookieCloud 服务器地址格式不正确');
    }
    return uri;
  }

  /// 拉取服务端保存的密文。
  Future<String> fetchEncrypted({required String host, required String uuid}) async {
    if (uuid.trim().isEmpty) {
      throw const CookieCloudException('UUID 不能为空');
    }
    final Uri uri = buildGetUri(host, uuid);
    try {
      final Response<dynamic> response = await _dio.getUri<dynamic>(
        uri,
        options: Options(
          sendTimeout: AppConfig.importTimeout,
          receiveTimeout: AppConfig.importTimeout,
        ),
      );
      final Object? data = response.data;
      if (data is Map && data['encrypted'] is String) {
        return data['encrypted'] as String;
      }
      throw const CookieCloudException('服务器未返回 encrypted 字段，请确认 UUID 是否正确');
    } on DioException catch (error) {
      throw CookieCloudException('拉取 CookieCloud 数据失败：${error.message ?? error.type.name}');
    }
  }

  /// 解密为结构化数据。
  CookieCloudBundle decryptBundle({
    required String uuid,
    required String password,
    required String encrypted,
  }) {
    final String plain = CookieCloudCrypto.decryptToString(
      uuid: uuid,
      password: password,
      encrypted: encrypted,
    );
    final Object? decoded = jsonDecode(plain);
    if (decoded is! Map<String, dynamic>) {
      throw const CookieCloudException('解密结果不是预期的 JSON 对象');
    }
    return CookieCloudBundle.parse(decoded);
  }

  /// 拉取 + 解密。
  Future<CookieCloudBundle> fetchAndImport({
    required String host,
    required String uuid,
    required String password,
  }) async {
    final String encrypted = await fetchEncrypted(host: host, uuid: uuid);
    return decryptBundle(uuid: uuid, password: password, encrypted: encrypted);
  }
}