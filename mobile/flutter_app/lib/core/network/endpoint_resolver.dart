import 'package:dio/dio.dart';

import '../config/app_config.dart';

/// 链路模式：自动（LAN 优先，失败回退 WAN）/ 强制内网 / 强制外网。
enum LinkMode {
  auto,
  lan,
  wan;

  static LinkMode fromName(String? value) {
    switch (value) {
      case 'lan':
        return LinkMode.lan;
      case 'wan':
        return LinkMode.wan;
      case 'auto':
      default:
        return LinkMode.auto;
    }
  }

  String get label => switch (this) {
        LinkMode.auto => '自动',
        LinkMode.lan => '内网',
        LinkMode.wan => '外网',
      };
}

/// 当前实际生效的链路。
enum ActiveLink {
  lan,
  wan,
  none;

  String get label => switch (this) {
        ActiveLink.lan => '内网',
        ActiveLink.wan => '外网',
        ActiveLink.none => '未连接',
      };
}

/// 探测函数：给定候选基址与超时，返回该链路是否可用（以 API 健康状态为准）。
typedef EndpointProbe = Future<bool> Function(Uri candidate, Duration timeout);

/// 双通道服务地址档案（需求 #16：内外网两种访问方式，外网为 lucky 反代）。
class EndpointProfile {
  const EndpointProfile({
    this.lanBaseUrl,
    this.wanBaseUrl,
    this.mode = LinkMode.auto,
  });

  final Uri? lanBaseUrl;
  final Uri? wanBaseUrl;
  final LinkMode mode;

  bool get hasLan => lanBaseUrl != null && lanBaseUrl!.host.isNotEmpty;
  bool get hasWan => wanBaseUrl != null && wanBaseUrl!.host.isNotEmpty;
  bool get isConfigured => hasLan || hasWan;

  EndpointProfile copyWith({Uri? lanBaseUrl, Uri? wanBaseUrl, LinkMode? mode}) => EndpointProfile(
        lanBaseUrl: lanBaseUrl ?? this.lanBaseUrl,
        wanBaseUrl: wanBaseUrl ?? this.wanBaseUrl,
        mode: mode ?? this.mode,
      );
}

/// 已解析的可用端点。
class ResolvedEndpoint {
  const ResolvedEndpoint({required this.baseUrl, required this.link, required this.resolvedAt});

  final Uri baseUrl;
  final ActiveLink link;
  final DateTime resolvedAt;

  bool isExpired(Duration ttl, DateTime now) => now.difference(resolvedAt) >= ttl;
}

/// 链路解析器：按「LAN 优先，失败回退 WAN」选择 NAS 服务地址，并缓存结果。
///
/// - 自动模式：先以内网 2 秒探测 LAN，失败再用外网 10 秒探测 WAN；
/// - 已缓存为 WAN 时，仍先尝试 LAN，回到家庭网络后能自动切回（需求 #16）；
/// - [invalidate] 在系统网络切换事件或请求失败后调用，立即清理旧缓存；
/// - 强制模式（lan/wan）跳过另一通道，便于排障。
class EndpointResolver {
  EndpointResolver({
    required this.probe,
    EndpointProfile? profile,
    Duration? cacheTtl,
    DateTime Function()? clock,
  })  : _profile = profile ?? const EndpointProfile(),
        _cacheTtl = cacheTtl ?? AppConfig.endpointCacheTtl,
        _clock = clock ?? DateTime.now;

  /// 探测实现：默认注入 HTTP 健康探测，测试中可替换为纯函数。
  final EndpointProbe probe;

  final Duration _cacheTtl;
  final DateTime Function() _clock;

  EndpointProfile _profile;
  ResolvedEndpoint? _cached;

  EndpointProfile get profile => _profile;

  ResolvedEndpoint? get cached => _cached;

  set profile(EndpointProfile value) {
    _profile = value;
    invalidate();
  }

  /// 最近一次选路结果（可能为 null）。
  ActiveLink get activeLink => _cached?.link ?? ActiveLink.none;

  /// 清理缓存：网络切换监听 / 请求失败 / 配置变更时调用。
  void invalidate() => _cached = null;

  /// 解析可用端点；命中未过期缓存时直接返回。
  Future<ResolvedEndpoint> resolve({bool force = false}) async {
    final DateTime now = _clock();
    final ResolvedEndpoint? cached = _cached;
    if (!force && cached != null && !cached.isExpired(_cacheTtl, now)) {
      return cached;
    }

    final ResolvedEndpoint? resolved = await _select();
    if (resolved != null) {
      _cached = resolved;
      return resolved;
    }

    // 全部失败：抛出明确错误交由上层展示（不回退到无效地址）。
    throw EndpointUnavailableException(_profile);
  }

  Future<ResolvedEndpoint?> _select() async {
    final LinkMode mode = _profile.mode;

    if (mode == LinkMode.lan) {
      return _probeLink(_profile.lanBaseUrl, ActiveLink.lan, AppConfig.lanProbeTimeout);
    }
    if (mode == LinkMode.wan) {
      return _probeLink(_profile.wanBaseUrl, ActiveLink.wan, AppConfig.wanProbeTimeout);
    }

    // 自动模式：LAN 优先，失败回退 WAN。
    if (_profile.hasLan) {
      final ResolvedEndpoint? lan =
          await _probeLink(_profile.lanBaseUrl, ActiveLink.lan, AppConfig.lanProbeTimeout);
      if (lan != null) return lan;
    }
    if (_profile.hasWan) {
      return _probeLink(_profile.wanBaseUrl, ActiveLink.wan, AppConfig.wanProbeTimeout);
    }
    return null;
  }

  Future<ResolvedEndpoint?> _probeLink(Uri? candidate, ActiveLink link, Duration timeout) async {
    if (candidate == null || candidate.host.isEmpty) return null;
    final bool ok = await probe(candidate, timeout);
    if (!ok) return null;
    return ResolvedEndpoint(baseUrl: candidate, link: link, resolvedAt: _clock());
  }
}

/// 无任何可用链路时抛出。
class EndpointUnavailableException implements Exception {
  const EndpointUnavailableException(this.profile);

  final EndpointProfile profile;

  @override
  String toString() => profile.isConfigured ? '内网与外网地址均不可用' : '尚未配置 NAS 服务地址';
}

/// 默认健康探测实现：GET /api/v1/health，2xx 视为可用。
///
/// 独立于业务客户端，使用最小化 Dio 实例，避免依赖解析结果造成循环。
class HttpHealthProbe {
  HttpHealthProbe({Dio? dio, this.healthPath = AppConfig.healthPath}) : _dio = dio ?? Dio();

  final Dio _dio;
  final String healthPath;

  Future<bool> call(Uri candidate, Duration timeout) async {
    try {
      final Uri target = candidate.resolve(healthPath);
      final Response<dynamic> response = await _dio.getUri<dynamic>(
        target,
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
          followRedirects: true,
          validateStatus: (int? status) => status != null && status >= 200 && status < 300,
        ),
      );
      return response.statusCode != null && response.statusCode! >= 200 && response.statusCode! < 300;
    } on DioException {
      return false;
    }
  }
}