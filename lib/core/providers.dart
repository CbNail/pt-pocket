import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/endpoint.dart';
import 'package:pt_pocket/core/network/guardian_client.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/network/qb_client.dart';
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

/// Guardian 双链路 + 令牌（旧版单地址自动迁移为内网地址）
final guardianConnProvider = FutureProvider<GuardianConn>((ref) async {
  var lan = await SecureStore.read(SecureStore.guardianLanUrl);
  final wan = await SecureStore.read(SecureStore.guardianWanUrl);
  final legacy = await SecureStore.read(SecureStore.guardianUrl);
  final modeStr = await SecureStore.read(SecureStore.guardianMode);
  final token = await SecureStore.read(SecureStore.guardianToken);

  if (token == null || token.isEmpty) throw GuardianNotConfigured();
  if (lan == null || lan.isEmpty) lan = legacy;
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

/// 全局选路器（保存配置时 reset）
final guardianResolverProvider =
    Provider<EndpointResolver>((ref) => EndpointResolver());

/// Guardian 监测状态（失败自动换链路重试一次）
final guardianStatusProvider = FutureProvider<List<GuardianSite>>((ref) async {
  final conn = await ref.watch(guardianConnProvider.future);
  final resolver = ref.watch(guardianResolverProvider);

  Future<List<GuardianSite>> attempt() async {
    final r = await resolver.resolve(conn.endpoint, probePath: '/health');
    try {
      final client =
          GuardianClient.build(GuardianConfig(url: r.url, token: conn.token));
      return await client.fetchStatus();
    } catch (_) {
      resolver.reportFailure(r.url);
      rethrow;
    }
  }

  try {
    return await attempt();
  } catch (_) {
    return attempt();
  }
});

/// 当前链路徽标 —— 任何异常都吞掉返回 null，绝不让 AppBar 崩溃
final guardianLinkProvider = FutureProvider<LinkInfo?>((ref) async {
  try {
    final conn = await ref.watch(guardianConnProvider.future);
    final resolver = ref.watch(guardianResolverProvider);
    final ep = conn.endpoint;
    final r = await resolver.resolve(ep, probePath: '/health');
    if (!ep.isDual) return null;
    return switch (ep.mode) {
      EndpointMode.lanOnly => const LinkInfo('强制内网', true),
      EndpointMode.wanOnly => const LinkInfo('强制外网', false),
      EndpointMode.auto => r.isLan
          ? const LinkInfo('内网直连', true)
          : const LinkInfo('外网中转', false),
    };
  } catch (_) {
    return null;
  }
});

/// M-Team API Key 配置（公网 API，不涉及双链路）
final mteamConfigProvider = FutureProvider<MTeamConfig?>((ref) async {
  final key = await SecureStore.read(MTeamClient.storageKey);
  if (key == null || key.isEmpty) return null;
  return MTeamConfig(apiKey: key);
});

/// qBittorrent 双链路 + 账号
final qbConnProvider = FutureProvider<QbConfig>((ref) async {
  final lan = await SecureStore.read(SecureStore.qbLanUrl);
  final wan = await SecureStore.read(SecureStore.qbWanUrl);
  final modeStr = await SecureStore.read(SecureStore.qbMode);
  final username = await SecureStore.read(SecureStore.qbUsername);
  final password = await SecureStore.read(SecureStore.qbPassword);
  if (username == null ||
      username.isEmpty ||
      password == null ||
      password.isEmpty) {
    throw QbNotConfigured();
  }
  final ep = DualEndpoint(
    lanUrl: (lan == null || lan.isEmpty) ? null : lan,
    wanUrl: (wan == null || wan.isEmpty) ? null : wan,
    mode: switch (modeStr) {
      'lan' => EndpointMode.lanOnly,
      'wan' => EndpointMode.wanOnly,
      _ => EndpointMode.auto,
    },
  );
  if (!ep.hasAny) throw QbNotConfigured();
  return QbConfig(endpoint: ep, username: username, password: password);
});

final qbResolverProvider =
    Provider<EndpointResolver>((ref) => EndpointResolver());