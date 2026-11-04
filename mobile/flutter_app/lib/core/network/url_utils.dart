/// 地址归一化与拼接：集中处理“用户手填的服务地址”的各种形态。
///
/// 自建服务地址有三种常见写法，必须都能落成可用的 URI：
/// 1. 内网直连：`192.168.5.206:45005`（无协议，纯 http）；
/// 2. 反代入口：`https://xxx.xyz:5888`（有协议、带非标准端口）；
/// 3. 反代子路径：`https://xxx.xyz:5888/ptp`（基址自带一段路径）。
///
/// 拼接 API 路径时**必须保留基址里已有的子路径**，否则反代挂载在子路径下的
/// 服务会被误判为不可达（这是“地址明明能打开，App 却报不可达”的一个直接原因）。
library;

abstract final class UrlUtils {
  /// 内网 / 回环 / 保留网段主机，以及常见的家庭内网域名后缀。
  static bool isPrivateHost(String host) {
    final String h = host.trim().toLowerCase();
    if (h.isEmpty) return false;
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    for (final String suffix in const <String>['.local', '.lan', '.home', '.internal', '.arpa']) {
      if (h.endsWith(suffix)) return true;
    }
    final RegExpMatch? ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
    if (ipv4 != null) {
      final int a = int.parse(ipv4.group(1)!);
      final int b = int.parse(ipv4.group(2)!);
      if (a == 10 || a == 127) return true;
      if (a == 192 && b == 168) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 169 && b == 254) return true;
      return false;
    }
    // IPv6 字面量（含方括号）一律按直连处理。
    if (h.startsWith('[') || h.contains(':')) return true;
    return false;
  }

  /// 缺协议时猜测协议：内网主机补 `http`，公网主机补 `https`。
  static String guessScheme(String host) => isPrivateHost(host) ? 'http' : 'https';

  /// 主机名是否可信：空串、带空白与分隔符的输入一律拒绝。
  ///
  /// 说明：`Uri.tryParse` 对 `https://not a host` 这种输入是**宽容的**，
  /// 会把它百分号编码成合法 URI；这里先挡下来，避免把错地址当成对地址用。
  static bool _isPlausibleHost(String host) {
    if (host.isEmpty) return false;
    return !host.contains(RegExp(r'[\s@/?&#]'));
  }

  /// 归一化用户填写的服务地址。
  ///
  /// - 缺协议按 [guessScheme] 补；
  /// - 保留显式端口与反代子路径；
  /// - 丢弃 query 与 fragment（否则拼接 API 路径会把路径截断）；
  /// - 去掉末尾斜杠，方便与 `+ '/api/v1/...'` 直接拼接。
  ///
  /// 解析失败返回 `null`，由调用方给出提示，绝不静默替换成其他地址。
  static Uri? normalize(String? raw) {
    if (raw == null) return null;
    String value = raw.trim();
    if (value.isEmpty) return null;

    if (!value.contains('://')) {
      final String hostPart = value.split('/').first.split(':').first;
      if (!_isPlausibleHost(hostPart)) return null;
      value = '${guessScheme(hostPart)}://$value';
    } else {
      final String authority = value.substring(value.indexOf('://') + 3).split('/').first;
      final String hostPart = authority.split('@').last.split(':').first;
      if (!_isPlausibleHost(hostPart)) return null;
    }

    final Uri? parsed = Uri.tryParse(value);
    if (parsed == null || parsed.host.isEmpty) return null;
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;

    String path = parsed.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }

    return Uri(
      scheme: parsed.scheme,
      host: parsed.host,
      port: parsed.hasPort ? parsed.port : null,
      path: path,
    );
  }

  /// 把 API 路径拼到基址之后，保留基址已有的子路径与端口。
  ///
  /// 例：`https://h:5888/ptp` + `/api/v1/health` → `https://h:5888/ptp/api/v1/health`。
  ///
  /// 不使用 `Uri.resolve`：它对以 `/` 开头的路径会**丢掉基址路径**。
  static Uri joinPath(Uri base, String path) {
    final String baseText = base.toString();
    final String suffix = path.startsWith('/') ? path : '/$path';
    final String joined =
        baseText.endsWith('/') ? '$baseText${suffix.substring(1)}' : '$baseText$suffix';
    return Uri.parse(joined);
  }

  /// 展示用地址（去掉可能存在的 userInfo，避免把凭据打到界面上）。
  static String display(Uri? uri) {
    if (uri == null) return '';
    if (uri.userInfo.isEmpty) return uri.toString();
    return uri.replace(userInfo: '').toString();
  }
}