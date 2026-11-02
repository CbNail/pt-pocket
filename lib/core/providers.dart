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

/// 一次成功拉取的快照：站点数据 + 本次实际走的链路
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

/// 全局选路器（网络切换/保存配置时 reset）
final guardianResolverProvider =
    Provider<EndpointResolver>((ref
