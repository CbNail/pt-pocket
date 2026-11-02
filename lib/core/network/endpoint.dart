import 'package:dio/dio.dart';

/// 链路模式：自动（内网优先）/ 强制内网 / 强制外网
enum EndpointMode { auto, lanOnly, wanOnly }

/// 一个自建服务的双链路端点
class DualEndpoint {
  const DualEndpoint({this.lanUrl, this.wanUrl, this.mode = EndpointMode.auto});

  final String? lanUrl;
  final String? wanUrl;
  final EndpointMode mode;

  bool get _hasL => lanUrl != null && lanUrl!.trim().isNotEmpty;
  bool get _hasW => wanUrl != null && wanUrl!.trim().isNotEmpty;
  bool get hasAny => _hasL || _hasW;
  bool get isDual => _hasL && _hasW;
}

/// 选路结果
class ResolvedEndpoint {
  const ResolvedEndpoint({required this.url, required this.isLan});
  final String url;
  final bool isLan;
}

/// 自动选路器：内网优先，失败自动切外网；带 5 分钟缓存，失败即作废
class EndpointResolver {
  String? _lastGood;
  bool? _lastGoodIsLan;
  DateTime _checkedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _ttl = Duration(minutes: 5);

  void reset() {
    _lastGood = null;
    _lastGoodIsLan = null;
    _checkedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<bool> _probe(String base, String probePath, Duration timeout) async {
    try {
      await Dio(BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        validateStatus: (c) => c != null && c < 500,
      )).get('${_strip(base)}$probePath');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 返回本次应使用的地址；全都不可达时抛异常
  Future<ResolvedEndpoint> resolve(DualEndpoint ep,
      {String probePath = '/health'}) async {
    if (ep.mode == EndpointMode.lanOnly) {
      if (!ep._hasL) throw Exception('已强制内网，但未填写内网地址');
      return ResolvedEndpoint(url: _strip(ep.lanUrl!), isLan: true);
    }
    if (ep.mode == EndpointMode.wanOnly) {
      if (!ep._hasW) throw Exception('已强制外网，但未填写外网地址');
      return ResolvedEndpoint(url: _strip(ep.wanUrl!), isLan: false);
    }

    // auto：单链路直接用
    if (!ep.isDual) {
      if (ep._hasL) return ResolvedEndpoint(url: _strip(ep.lanUrl!), isLan: true);
      if (ep._hasW) return ResolvedEndpoint(url: _strip(ep.wanUrl!), isLan: false);
      throw Exception('未配置任何地址');
    }

    // 双链路：缓存新鲜直接用
    final fresh = DateTime.now().difference(_checkedAt) < _ttl;
    if (fresh && _lastGood != null) {
      return ResolvedEndpoint(url: _lastGood!, isLan: _lastGoodIsLan ?? true);
    }

    // 内网快探（2s）→ 外网慢探（6s）
    if (await _probe(ep.lanUrl!, probePath, const Duration(milliseconds: 2000))) {
      _cache(ep.lanUrl!, true);
      return ResolvedEndpoint(url: _strip(ep.lanUrl!), isLan: true);
    }
    if (await _probe(ep.wanUrl!, probePath, const Duration(seconds: 6))) {
      _cache(ep.wanUrl!, false);
      return ResolvedEndpoint(url: _strip(ep.wanUrl!), isLan: false);
    }
    throw Exception('内网与外网均不可达');
  }

  /// 请求失败后调用：作废缓存，下次 resolve 重新探测并自动切换
  void reportFailure(String url) {
    if (_lastGood != null && _strip(url) == _lastGood) reset();
  }

  void _cache(String url, bool isLan) {
    _lastGood = _strip(url);
    _lastGoodIsLan = isLan;
    _checkedAt = DateTime.now();
  }

  static String _strip(String u) =>
      u.endsWith('/') ? u.substring(0, u.length - 1) : u;
}
