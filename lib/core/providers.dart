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

final guardianResolverProvider =
    Provider<EndpointResolver>((ref) => EndpointResolver());

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

final mteamConfigProvider = FutureProvider<MTeamConfig?>((ref) async {
  final key = await SecureStore.read(MTeamClient.storageKey);
  if (key == null || key.isEmpty) return null;
  return MTeamConfig(apiKey: key);
});

// ---------- 下载器 ----------

enum DownloaderType { qbittorrent, transmission }

class DownloaderRuntime {
  const DownloaderRuntime({
    required this.id,
    required this.type,
    required this.name,
    required this.endpoint,
    required this.username,
    required this.password,
    this.defaultPath,
  });
  final String id;
  final DownloaderType type;
  final String name;
  final DualEndpoint endpoint;
  final String username;
  final String password;
  final String? defaultPath;
}

String? _nn(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
EndpointMode _pm(String? s) =>
    s == 'lan' ? EndpointMode.lanOnly : s == 'wan' ? EndpointMode.wanOnly : EndpointMode.auto;

/// 已配置的下载器列表（qB / TR 各一台，填了账密+任一地址即生效）
final downloadersProvider = FutureProvider<List<DownloaderRuntime>>((ref) async {
  final list = <DownloaderRuntime>[];

  final qbUser = _nn(await SecureStore.read(SecureStore.qbUsername));
  final qbPass = _nn(await SecureStore.read(SecureStore.qbPassword));
  if (qbUser != null && qbPass != null) {
    final ep = DualEndpoint(
      lanUrl: _nn(await SecureStore.read(SecureStore.qbLanUrl)),
      wanUrl: _nn(await SecureStore.read(SecureStore.qbWanUrl)),
      mode: _pm(await SecureStore.read(SecureStore.qbMode)),
    );
    if (ep.hasAny) {
      final n = _nn(await SecureStore.read(SecureStore.qbName));
      list.add(DownloaderRuntime(
        id: 'qb',
        type: DownloaderType.qbittorrent,
        name: n ?? 'qBittorrent',
        endpoint: ep,
        username: qbUser,
        password: qbPass,
        defaultPath: _nn(await SecureStore.read(SecureStore.qbPath)),
      ));
    }
  }

  final trUser = _nn(await SecureStore.read(SecureStore.trUsername));
  final trPass = _nn(await SecureStore.read(SecureStore.trPassword));
  if (trUser != null && trPass != null) {
    final ep = DualEndpoint(
      lanUrl: _nn(await SecureStore.read(SecureStore.trLanUrl)),
      wanUrl: _nn(await SecureStore.read(SecureStore.trWanUrl)),
      mode: _pm(await SecureStore.read(SecureStore.trMode)),
    );
    if (ep.hasAny) {
      final n = _nn(await SecureStore.read(SecureStore.trName));
      list.add(DownloaderRuntime(
        id: 'tr',
        type: DownloaderType.transmission,
        name: n ?? 'Transmission',
        endpoint: ep,
        username: trUser,
        password: trPass,
        defaultPath: _nn(await SecureStore.read(SecureStore.trPath)),
      ));
    }
  }
  return list;
});
