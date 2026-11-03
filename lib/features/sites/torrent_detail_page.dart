import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/push_service.dart';

class TorrentDetailPage extends ConsumerStatefulWidget {
  const TorrentDetailPage({super.key, required this.torrent});
  final MTeamTorrent torrent;

  @override
  ConsumerState<TorrentDetailPage> createState() => _TorrentDetailPageState();
}

class _TorrentDetailPageState extends ConsumerState<TorrentDetailPage> {
  List<DownloaderRuntime> _dls = const [];
  bool _loadingDl = true;
  int _sel = 0;
  final _path = TextEditingController();
  bool _busy = false;
  bool _ok = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _loadDls();
  }

  Future<void> _loadDls() async {
    try {
      final dls = await ref.read(downloadersProvider.future);
      if (!mounted) return;
      setState(() {
        _dls = dls;
        _loadingDl = false;
        if (dls.isNotEmpty) _path.text = dls.first.defaultPath ?? '';
      });
    } catch (_) {
      if (mounted) setState(() => _loadingDl = false);
    }
  }

  Future<void> _push() async {
    if (_busy) return;
    if (_dls.isEmpty) {
      setState(() {
        _ok = false;
        _status = '还未配置下载器：请到「下载器」标签页添加并保存';
      });
      return;
    }
    final d = _dls[_sel];
    setState(() {
      _busy = true;
      _ok = false;
      _status = '① 正在获取下载链接（genDLink，最长 45s）…';
    });

    String magnet;
    try {
      final cfg = await ref.read(mteamConfigProvider.future);
      if (cfg == null) throw Exception('未配置 M-Team API Key（站点管理）');
      magnet = await MTeamClient.build(cfg).genDLink(widget.torrent.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '① 获取下载链接失败：$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _status = '② 正在推送到 ${d.name}（双链路自动切换）…');

    try {
      final used = await pushToDownloader(
          dl: d, magnet: magnet, savePath: _path.text.trim());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _ok = true;
        _status =
            '✅ 已推送到 ${d.name}（$used）· ${_path.text.trim().isEmpty ? "默认目录" : _path.text.trim()}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '② 推送失败：$e';
      });
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
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
              child: Column(children: [
                _Row(label: '体积', value: t.sizeText),
                _Row(
                    label: '做种 / 下载',
                    value: '${t.seeders ?? '-'} / ${t.leechers ?? '-'}'),
                _Row(label: '完成', value: '${t.snatches ?? '-'}'),
                if (t.createdText != null)
                  _Row(label: '发布时间', value: t.createdText!),
                _Row(label: '种子 ID', value: t.id),
              ]),
            ),
          ),
          const SizedBox(height: 24),
          Text('推送到下载器', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('磁力链直接发送到所选下载器（双链路自动切换），下载由服务器完成',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 12),
          if (_loadingDl)
            const LinearProgressIndicator()
          else if (_dls.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('还未配置下载器：请到「下载器」标签页添加 qBittorrent 或 Transmission'),
              ),
            )
          else ...[
            if (_dls.length > 1)
              SegmentedButton<int>(
                segments: [
                  for (var i = 0; i < _dls.length; i++)
                    ButtonSegment(
                        value: i,
                        label: Text(_dls[i].name,
                            overflow: TextOverflow.ellipsis)),
                ],
                selected: {_sel},
                onSelectionChanged: (s) => setState(() {
                  _sel = s.first;
                  _path.text = _dls[_sel].defaultPath ?? '';
                }),
              )
            else
              Row(children: [
                Icon(
                    _dls.first.type == DownloaderType.qbittorrent
                        ? Icons.grid_view_outlined
                        : Icons.swap_horiz,
                    size: 18,
                    color: Colors.white54),
                const SizedBox(width: 6),
                Text('目标：${_dls.first.name}',
                    style: const TextStyle(color: Colors.white70)),
              ]),
            const SizedBox(height: 12),
            TextField(
              controller: _path,
              decoration: const InputDecoration(
                labelText: '保存目录',
                prefixIcon: Icon(Icons.folder_outlined),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _busy ? null : _push,
              icon: const Icon(Icons.download_for_offline_outlined),
              label: Text(_dls.isEmpty
                  ? '推送到下载器'
                  : '推送到 ${_dls[_sel].name} 下载'),
            ),
          ],
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
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 96,
            child:
                Text(label, style: const TextStyle(color: Colors.white38))),
        Expanded(child: Text(value)),
      ]),
    );
  }
}
