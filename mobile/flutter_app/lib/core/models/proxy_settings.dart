/// App 自身网络代理设置（需求 13：可添加自建旁路由中提供的代理服务）。
///
/// 当前只支持 HTTP 代理：Dart 网络栈（dart:io）的代理指令只识别
/// `DIRECT` 与 `PROXY host:port` 两种形式，不支持 SOCKS5；
/// 代理密码不落在普通配置里，只存本机安全存储。
library;

/// 代理类型（预留扩展位；当前仅 HTTP 代理可生效）。
enum ProxyType {
  http('HTTP 代理', '经 CONNECT 隧道转发请求，Dart 网络栈原生支持');

  const ProxyType(this.label, this.description);

  final String label;
  final String description;

  static ProxyType fromName(String? value) => values.firstWhere(
        (ProxyType t) => t.name == value,
        orElse: () => ProxyType.http,
      );
}

/// 代理配置（非机密部分）。
class ProxySettings {
  const ProxySettings({
    this.enabled = false,
    this.type = ProxyType.http,
    this.host = '',
    this.port = 0,
    this.useAuth = false,
    this.username = '',
  });

  final bool enabled;
  final ProxyType type;
  final String host;
  final int port;
  final bool useAuth;
  final String username;

  bool get isConfigured => host.trim().isNotEmpty && port > 0;

  /// 是否可真正生效。
  bool get isUsable => enabled && isConfigured;

  /// 本地/内网主机应直连，避免把家庭网络流量绕到代理上。
  bool get bypassPrivateHosts => true;

  String get endpoint => '${host.trim()}:$port';

  String get summary => isUsable
      ? '${type.label} · $endpoint${useAuth ? ' · 已启用认证' : ''}'
      : (enabled ? '已开启但未填写完整' : '未启用');

  /// 针对目标地址给出代理指令（dart:io 的 findProxy 返回值）。
  String directiveFor(Uri uri, {bool bypassPrivate = true}) {
    if (!isUsable) return 'DIRECT';
    if (bypassPrivate && isPrivateHost(uri.host)) return 'DIRECT';
    return 'PROXY $endpoint';
  }

  /// 判断是否内网/本机地址。
  static bool isPrivateHost(String host) {
    final String value = host.toLowerCase().trim();
    if (value.isEmpty) return true;
    if (value == 'localhost' ||
        value.endsWith('.local') ||
        value.endsWith('.lan') ||
        value.endsWith('.internal') ||
        value.endsWith('.home')) {
      return true;
    }
    // 单标签主机名（如 nas、pve）按内网处理。
    if (!value.contains('.')) return true;

    final RegExpMatch? match = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(value);
    if (match == null) return false;
    final int a = int.parse(match.group(1)!);
    final int b = int.parse(match.group(2)!);
    if (a == 10 || a == 127) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT
    if (a == 169 && b == 254) return true; // 链路本地
    return false;
  }

  ProxySettings copyWith({
    bool? enabled,
    ProxyType? type,
    String? host,
    int? port,
    bool? useAuth,
    String? username,
  }) =>
      ProxySettings(
        enabled: enabled ?? this.enabled,
        type: type ?? this.type,
        host: host ?? this.host,
        port: port ?? this.port,
        useAuth: useAuth ?? this.useAuth,
        username: username ?? this.username,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'type': type.name,
        'host': host,
        'port': port,
        'useAuth': useAuth,
        'username': username,
      };

  factory ProxySettings.fromJson(Map<String, dynamic> json) => ProxySettings(
        enabled: json['enabled'] as bool? ?? false,
        type: ProxyType.fromName(json['type'] as String?),
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 0,
        useAuth: json['useAuth'] as bool? ?? false,
        username: json['username'] as String? ?? '',
      );
}