import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../config/app_config.dart';
import 'endpoint_resolver.dart';

/// 链路守护：网络环境变化或周期性复检时让选路缓存失效，
/// 使下一次请求重新按「内网优先、失败回退外网」选路（需求 16）。
///
/// 只做「缓存失效」这一件事：
/// - 从移动数据回到家庭 Wi‑Fi 时立即失效，下次请求自动切回内网；
/// - 离开家庭网络时立即失效，下次请求自动回退外网（lucky 反代）；
/// - 周期性复检兜底系统未上报的变化。
class LinkSupervisor {
  LinkSupervisor({
    required this.resolver,
    Stream<List<ConnectivityResult>>? changes,
    Duration? revalidateInterval,
  })  : _changes = changes ?? Connectivity().onConnectivityChanged,
        _revalidateInterval = revalidateInterval ?? AppConfig.healthProbeInterval;

  final EndpointResolver resolver;
  final Stream<List<ConnectivityResult>> _changes;
  final Duration _revalidateInterval;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _timer;
  int _revalidationCount = 0;

  bool get isRunning => _subscription != null;

  /// 已发生的失效次数（诊断用）。
  int get revalidationCount => _revalidationCount;

  /// 启动监听（幂等，可重复调用）。
  void start() {
    _subscription ??= _changes.listen((List<ConnectivityResult> results) => revalidate());
    _timer ??= Timer.periodic(_revalidateInterval, (_) => revalidate());
  }

  /// 使选路缓存失效。
  void revalidate() {
    _revalidationCount++;
    resolver.invalidate();
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _timer?.cancel();
    _timer = null;
  }
}