import 'package:pt_pocket/core/network/endpoint.dart';
import 'package:pt_pocket/core/network/qb_client.dart';
import 'package:pt_pocket/core/network/tr_client.dart';
import 'package:pt_pocket/core/providers.dart';

/// 统一推送：双链路自动选路 + 按类型分发；失败自动换链路重试一次。
/// 返回实际使用的链路描述（内网直连 / 外网中转）
Future<String> pushToDownloader({
  required DownloaderRuntime dl,
  required String magnet,
  String? savePath,
}) async {
  final resolver = EndpointResolver();
  final probe = dl.type == DownloaderType.qbittorrent
      ? '/api/v2/app/version'
      : '/transmission/rpc';

  Future<String> attempt() async {
    final r = await resolver.resolve(dl.endpoint, probePath: probe);
    try {
      if (dl.type == DownloaderType.qbittorrent) {
        final c = QbClient.build(
            baseUrl: r.url, username: dl.username, password: dl.password);
        await c.login();
        await c.addByUrl(magnet, savePath: savePath);
      } else {
        final c = TrClient.build(
            baseUrl: r.url, username: dl.username, password: dl.password);
        await c.addTorrent(magnet, downloadDir: savePath);
      }
      return r.isLan ? '内网直连' : '外网中转';
    } catch (e) {
      resolver.reportFailure(r.url);
      rethrow;
    }
  }

  try {
    return await attempt();
  } catch (_) {
    return await attempt();
  }
}

/// 测试连接：双链路依次尝试，全失败抛合并错误
Future<String> testDownloader(DownloaderRuntime dl) async {
  final resolver = EndpointResolver();
  final probe = dl.type == DownloaderType.qbittorrent
      ? '/api/v2/app/version'
      : '/transmission/rpc';

  Future<String> once() async {
    final r = await resolver.resolve(dl.endpoint, probePath: probe);
    try {
      if (dl.type == DownloaderType.qbittorrent) {
        final c = QbClient.build(
            baseUrl: r.url, username: dl.username, password: dl.password);
        await c.login();
        final v = await c.version();
        return '${r.isLan ? "内网" : "外网"}链路可用：${r.url}\nqB v$v';
      } else {
        final c = TrClient.build(
            baseUrl: r.url, username: dl.username, password: dl.password);
        final v = await c.version();
        return '${r.isLan ? "内网" : "外网"}链路可用：${r.url}\nTR v$v';
      }
    } catch (e) {
      resolver.reportFailure(r.url);
      rethrow;
    }
  }

  try {
    return await once();
  } catch (e1) {
    try {
      final msg = await once();
      return '✅ 首选链路失败，已自动切换\n$msg';
    } catch (e2) {
      throw Exception('双链路均失败\n首选: $e1\n备选: $e2');
    }
  }
}
