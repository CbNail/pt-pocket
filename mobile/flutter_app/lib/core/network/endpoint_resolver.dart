import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'url_utils.dart';

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

/// 健康探测结果：把「地址能不能连上」与「后端是否就绪」分开表达。
///
/// 自建服务常见这样的状态：反代本身可达（能返回 HTTP），但后端 `/api/v1/health`
/// 还没部署或返回 404。旧实现把两者都显示成「不可用」，会让人误以为地址填错。
class HealthProbeResult {
  const HealthProbeResult({
    required this.reachable,
    required this.apiHealthy,
    this.statusCode,
    this.looksLikeApi = false,
    this.message = '',
    this.errorType,
  });

  /// 是否拿到了 HTTP 响应（含 4xx / 5xx，说明网络与地址本身没问题）。
  final bool reachable;

  /// `/api/v1/health` 是否返回 2xx；链路选路以此为准。
  final bool apiHealthy;

  final int? statusCode;

  /// 2xx 且响应体是 JSON，用于排除「反代到了别的服务」这种假健康。
  final bool looksLikeApi;

  final String message;

  /// `timeout` / `dns` / `tls` / `cancel` / `other`，供界面与日志归因。
  final String? errorType;

  bool get isUsable => apiHealthy;

  /// 地址通、但后端未就绪。
  bool get reachableButNotReady => reachable && !apiHealthy;
}

/// 默认健康探测实现：GET {基址}/api/v1/health。
///
/// 独立于业务客户端，使用最小化 Dio 实例，避免依赖解析结果造成循环。
class HttpHealthProbe {
  HttpHealthProbe({Dio? dio, this.healthPath = AppConfig.healthPath}) : _dio = dio ?? Dio();

  final Dio _dio;
  final String healthPath;

  /// 选路用：只回答「这条链路当前能否真正干活」。
  ///
  /// 除 2xx 外还要求响应体是 JSON（或空体）：反代把请求转到了别的服务时
  /// 常返回 200 + HTML，这种「假健康」不能拿来选路。
  Future<bool> call(Uri candidate, Duration timeout) async {
    final HealthProbeResult result = await diagnose(candidate, timeout);
    return result.apiHealthy && result.looksLikeApi;
  }

  /// 诊断用：区分网络不可达与后端未就绪，并给出可执行的提示。
  Future<HealthProbeResult> diagnose(Uri candidate, Duration timeout) async {
    // 用拼接而不是 Uri.resolve：反代挂在子路径时，基址路径必须保留。
    final Uri target = UrlUtils.joinPath(candidate, healthPath);
    try {
      final Response<dynamic> response = await _dio.getUri<dynamic>(
        target,
        options: Options(
          sendTimeout: timeout,
          receiveTimeout: timeout,
          followRedirects: true,
          responseType: ResponseType.plain,
          validateStatus: (int? status) => status != null,
        ),
      );
      final int status = response.statusCode ?? 0;
      final bool ok = status >= 200 && status < 300;
      final bool json = _looksLikeApiBody(response.data);
      return HealthProbeResult(
        reachable: true,
        apiHealthy: ok,
        statusCode: status,
        looksLikeApi: ok && json,
        message: _reachableMessage(target: target, status: status, ok: ok, json: json),
      );
    } on DioException catch (error) {
      final String type = _errorType(error);
      return HealthProbeResult(
        reachable: false,
        apiHealthy: false,
        message: _unreachableMessage(target: target, error: error, type: type),
        errorType: type,
      );
    } catch (error) {
      return HealthProbeResult(
        reachable: false,
        apiHealthy: false,
        message: '探测失败：$error',
        errorType: 'other',
      );
    }
  }

  /// 2xx 且响应体像本后端的健康响应：JSON 对象/数组，或干脆是空体。
  static bool _looksLikeApiBody(Object? data) {
    if (data == null) return true;
    if (data is Map || data is List) return true;
    if (data is String) {
      final String text = data.trim();
      if (text.isEmpty) return true;
      return text.startsWith('{') || text.startsWith('[');
    }
    return false;
  }

  static String _errorType(DioException error) => switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          'timeout',
        DioExceptionType.badCertificate => 'tls',
        DioExceptionType.connectionError => 'dns',
        DioExceptionType.cancel => 'cancel',
        _ => 'other',
      };

  static String _reachableMessage({
    required Uri target,
    required int status,
    required bool ok,
    required bool json,
  }) {
    if (ok && json) return '可达：$target 返回 HTTP $status（JSON 健康响应）';
    if (ok) return '可达但存疑：$target 返回 HTTP $status，响应不是 JSON，可能反代到了其它服务';
    return '地址可达、后端未就绪：$target 返回 HTTP $status';
  }

  static String _unreachableMessage({
    required Uri target,
    required DioException error,
    required String type,
  }) {
    switch (type) {
      case 'timeout':
        return '连接超时：$target 在超时内没有响应，可能是端口未开放或被防火墙/运营商拦截';
      case 'tls':
        return 'TLS 证书不受信任：$target 证书校验失败，请换用受信任证书或改用 http 内网地址';
      case 'dns':
        return '无法建立连接：$target 域名解析失败或端口未开放（${error.message ?? ''}）';
      case 'cancel':
        return '探测被取消：$target';
      default:
        return '连接失败：$target（${error.message ?? error.type.name}）';
    }
  }
}