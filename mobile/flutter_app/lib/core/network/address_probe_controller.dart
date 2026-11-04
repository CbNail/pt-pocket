import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/site_reachability_probe.dart';
import '../storage/probe_result_store.dart';
import 'endpoint_resolver.dart';

/// 统一探测签名：给定目标地址与超时，返回可直接落盘的结论。
typedef AddressProbe = Future<ProbeSnapshot> Function(Uri target, Duration timeout);

/// 由 NAS 健康探测结果构造快照。
///
/// `reachable` 表示拿到了 HTTP 响应；`usable` 额外要求 2xx 且是本服务的 JSON 健康响应
/// ——「地址通、后端未就绪」正是 reachable 为真、usable 为假。
ProbeSnapshot snapshotFromHealth(HealthProbeResult result, Uri target) => ProbeSnapshot(
      reachable: result.reachable,
      usable: result.apiHealthy && result.looksLikeApi,
      statusCode: result.statusCode,
      message: result.message,
      url: target.toString(),
      probedAt: DateTime.now(),
    );

/// 由站点 / 服务可达性探测结果构造快照。
///
/// 「需登录态」（401/403）说明地址通且服务在，只是缺凭据，因此 usable 也算通过。
ProbeSnapshot snapshotFromSiteProbe(SiteProbeResult result, Uri target) => ProbeSnapshot(
      reachable: result.outcome != SiteProbeOutcome.unreachable &&
          result.outcome != SiteProbeOutcome.invalidUrl,
      usable: result.isSuccess,
      statusCode: result.statusCode,
      message: result.message,
      url: target.toString(),
      probedAt: DateTime.now(),
    );

/// 地址探测协调器：把「录入完成 → 探测 → 落盘 → 通知界面」串起来。
///
/// 页面只需要：给每个地址注册一个 key 与目标地址、提供一个 [AddressProbe]，
/// 然后监听本对象刷新界面。结果会写进 [ProbeResultStore]，
/// 所以重新进入页面时显示的是上次真实结论，而不是「未检测」。
class AddressProbeController extends ChangeNotifier {
  AddressProbeController({
    required this.store,
    required this.probe,
    this.debounce = const Duration(milliseconds: 700),
    this.timeout = const Duration(seconds: 8),
  });

  final ProbeResultStore store;
  final AddressProbe probe;

  /// 录入停顿多久后自动探一次，避免每敲一个字符就打一次请求。
  final Duration debounce;
  final Duration timeout;

  final Map<String, ProbeSnapshot?> _results = <String, ProbeSnapshot?>{};
  final Set<String> _running = <String>{};
  final Map<String, Timer> _timers = <String, Timer>{};

  /// 最近一次结果：内存里的优先，没有则读落盘值。
  ProbeSnapshot? snapshot(String key) =>
      _results.containsKey(key) ? _results[key] : store.read(key);

  bool isProbing(String key) => _running.contains(key);

  /// 录入过程中调用：延时后自动探测一次；目标为空则清掉该 key 的结果。
  void schedule(String key, Uri? target) {
    _timers.remove(key)?.cancel();
    if (target == null) {
      _results[key] = null;
      notifyListeners();
      return;
    }
    _timers[key] = Timer(debounce, () => probeNow(key, target));
  }

  /// 立刻探测（点「测试」按钮、或进入页面按已存地址重测）。
  Future<void> probeNow(String key, Uri? target) async {
    _timers.remove(key)?.cancel();
    if (target == null || _running.contains(key)) return;

    _running.add(key);
    notifyListeners();

    ProbeSnapshot snapshot;
    try {
      snapshot = await probe(target, timeout);
    } catch (error) {
      snapshot = ProbeSnapshot(
        reachable: false,
        usable: false,
        message: '探测失败：$error',
        url: target.toString(),
        probedAt: DateTime.now(),
      );
    }

    _running.remove(key);
    _results[key] = snapshot;
    await store.write(key, snapshot);
    notifyListeners();
  }

  /// 清掉某个 key 的结果（地址被清空、记录被删除时用）。
  Future<void> forget(String key) async {
    _timers.remove(key)?.cancel();
    _results[key] = null;
    await store.clear(key);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final Timer timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}