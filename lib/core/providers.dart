import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/endpoint.dart';
import 'package:pt_pocket/core/network/guardian_client.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';

class GuardianConn {
  const GuardianConn({required this.endpoint, required this.token});
  final DualEndpoint endpoint;
  final String token;
}

class LinkInfo {
  const LinkInfo(this.label, this.isLan);
  final String label;
  final bool isLan;
}

/// 一次拉取的统一快照：站点数据 + 当时所走链路，保证徽标与数据永远一致
class GuardianSnapshot {
  const GuardianSnapshot({required this.sites, this.link});
  final List<GuardianSite> sites;
  final LinkInfo? link;
}

/// Guardian 双链路 + 令牌（旧版单地址自动迁移为内网地址）
final guardianConnProvider = FutureProvider<GuardianConn>((ref) async {
  var lan = await SecureStore.read(SecureStore.guardianLanUrl);
  final wan = await SecureStore.read(SecureStore.guardianWanUrl);
  final legacy = await SecureStore.read(SecureStore.guardianUrl);
  final modeStr = await SecureStore.read(SecureStore.guardianMode);
  final token = await SecureStore.read(SecureStore.guardianToken);

  if (token == null || token.isEmpty) throw GuardianNotConfigured();
  if (lan == null || lan.isEmpty) lan = legacy; // 旧配置迁移
  final ep = DualEndpoint(
    lanUrl: (lan == null || lan.isEmpty) ? null : lan,
    wanUrl: (wan == null || wan.isEmpty) ? null : wan,
    mode: switch (modeStr) {
      'lan' => EndpointMode.lanOnly,
      'wan' => EndpointMode.wanOnly,
      _ => EndpointMode.auto,
    },
  );
  if (!ep.hasAny) throw GuardianNotConfigured();
  return GuardianConn(endpoint: ep, token: token);
});

/// 全局选路器（保存配置 / 网络切换时 reset）
final guardianResolverProvider =
    Provider<EndpointResolver>((ref) => EndpointResolver());

/// Guardian 快照（失败自动换链路重试一次）
final guardianSnapshotProvider = FutureProvider<GuardianSnapshot>((ref) async {
  final conn = await ref.watch(guardianConnProvider.future);
  final resolver = ref.watch(guardianResolverProvider);

  Future<GuardianSnapshot> attempt() async {
    final r = await resolver.resolve(conn.endpoint, probePath: '/health');
    try {
      final client =
          GuardianClient.build(GuardianConfig(url: r.url, token: conn.token));
      final sites = await client.fetchStatus();
      final ep = conn.endpoint;
      return GuardianSnapshot(
        sites: sites,
        link: !ep.isDual
            ? null
            : LinkInfo(
                switch (ep.mode) {
                  EndpointMode.lanOnly => '强制内网',
                  EndpointMode.wanOnly => '强制外网',
                  EndpointMode.auto => r.isLan ? '内网直连' : '外网中转',
                },
                r.isLan,
              ),
      );
    } catch (_) {
      resolver.reportFailure(r.url);
      rethrow;
    }
  }

  try {
    return await attempt();
  } catch (_) {
    return attempt(); // 自动切换到另一条链路
  }
});

/// 网络切换哨兵：WiFi/流量/VPN 变化 → 作废选路缓存并自动刷新仪表盘
final connectivityRefresherProvider = Provider<void>((ref) {
  final startedAt = DateTime.now();
  Timer? debounce;
  final sub = Connectivity().onConnectivityChanged.listen((_) {
    // 启动初期系统会立刻回调一次当前状态，忽略之
    if (DateTime.now().difference(startedAt) < const Duration(seconds: 3)) {
      return;
    }
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 800), () {
      ref.read(guardianResolverProvider).reset();
      ref.invalidate(guardianSnapshotProvider);
    });
  });
  ref.onDispose(() {
    sub.cancel();
    debounce?.cancel();
  });
});

/// M-Team API Key 配置（公网 API，不涉及双链路）
final mteamConfigProvider = FutureProvider<MTeamConfig?>((ref) async {
  final key = await SecureStore.read(MTeamClient.storageKey);
  if (key == null || key.isEmpty) return null;
  return MTeamConfig(apiKey: key);
});
