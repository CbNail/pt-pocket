import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/network/qb_client.dart';
import 'package:pt_pocket/core/providers.dart';

class TorrentDetailPage extends ConsumerStatefulWidget {
  const TorrentDetailPage({super.key, required this.torrent});
  final MTeamTorrent torrent;

  @override
  ConsumerState<TorrentDetailPage> createState() => _TorrentDetailPageState();
}

class _TorrentDetailPageState extends ConsumerState<TorrentDetailPage> {
  bool _busy = false;
  bool _ok = false;
  String _status = '';

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ok = false;
      _status = msg;
    });
  }

  Future<void> _push() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _ok = false;
      _status = '① 正在获取下载链接（genDLink）…';
    });

    // ① M-Team 取磁力链
    String magnet;
    try {
      final cfg = await ref.read(mteamConfigProvider.future);
      if (cfg == null) throw Exception('未配置 M-Team API Key（站点管理）');
      magnet = await MTeamClient.build(cfg).genDLink(widget.torrent.id);
    } catch (e) {
      _fail('① 获取下载链接失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _status = '② 正在连接 qBittorrent…');

    // ② qB 推送（双链路自动切换）
    try {
      final conn = await ref.read(qbConnProvider.future);
      final resolver = ref.read(qbResolverProvider);

      Future<String> attempt() async {
        final r = await resolver.resolve(conn.endpoint,
            probePath: '/api/v2/app/version');
        try {
          final client = QbClient.build(
              baseUrl: r.url,
              username: conn.username,
              password: conn.password);
          await client.login();
          await client.addByUrl(magnet);
          return r.isLan ? '内网直连' : '外网中转';
        } catch (e) {
          resolver.reportFailure(r.url);
          rethrow;
        }
      }

      String used;
      try {
        used = await attempt();
      } catch (_) {
        used = await attempt(); // 自动切换另一条链路
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _ok = true;
        _status = '✅ 已推送到 qB（$used）· qBittorrent 开始下载';
      });
    } on QbNotConfigured {
      _fail('❌ $QbNotConfigured');
    } catch (e) {
      _fail('② 推送失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.torrent;
    return Scaffold(
      appBar: AppBar(title: const Text('种子详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(t.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              if (t.isFree)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('FREE',
                      style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          if (t.subtitle != null && t.subtitle!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(t.subtitle!,
                style: const TextStyle(color: Colors.white54, height: 1.4)),
          ],
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _Row(label: '体积', value: t.sizeText),
                  _Row(label: '做种 / 下载', value: '${t.seeders ?? '-'} / ${t.leechers ?? '-'}'),
                  _Row(label: '完成', value: '${t.snatches ?? '-'}'),
                  if (t.createdText != null)
                    _Row(label: '发布时间', value: t.createdText!),
                  _Row(label: '种子 ID', value: t.id),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('推送到下载器',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('磁力链将直接发送到 qBittorrent（双链路自动切换），下载由 qB 完成',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _push,
            icon: const Icon(Icons.download_for_offline_outlined),
            label: const Text('推送到 qB 下载'),
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_status,
                style: TextStyle(
                    color: _ok ? Colors.greenAccent : Colors.white70,
                    height: 1.5)),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 96,
              child: Text(label, style: const TextStyle(color: Colors.white38))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
