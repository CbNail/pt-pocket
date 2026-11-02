import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/network/qb_client.dart';
import 'package:pt_pocket/features/sites/site_manage_page.dart';
import 'package:pt_pocket/features/sites/torrent_detail_page.dart';

class SitesPage extends ConsumerStatefulWidget {
  const SitesPage({super.key});

  @override
  ConsumerState<SitesPage> createState() => _SitesPageState();
}

class _SitesPageState extends ConsumerState<SitesPage> {
  final _kw = TextEditingController();
  bool _loading = false;
  bool _notConfigured = false;
  String? _error;
  List<MTeamTorrent> _items = [];

  Future<void> _search() async {
    final kw = _kw.text.trim();
    if (kw.isEmpty || _loading) return;
    final cfg = await ref.read(mteamConfigProvider.future);
    if (!mounted) return;
    if (cfg == null) {
      setState(() {
        _notConfigured = true;
        _error = null;
        _items = [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _notConfigured = false;
      _error = null;
    });
    try {
      final items = await MTeamClient.build(cfg).search(kw);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _items = [];
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _kw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('站点 · M-Team'),
        actions: [
          IconButton(
            tooltip: '站点管理',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SiteManagePage())),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _kw,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: '搜索种子，如：荒野猎人',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _search,
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_notConfigured) {
      return _Hint(
        icon: Icons.vpn_key_outlined,
        title: '还未配置 M-Team API Key',
        subtitle: '点右上角 ⚙ 进入「站点管理」填入 Key，\n测试通过即自动保存，回来就能搜索。',
      );
    }
    if (_error != null) {
      return _Hint(
        icon: Icons.cloud_off_outlined,
        title: '搜索失败',
        subtitle: '$_error',
      );
    }
    if (_items.isEmpty) {
      return const _Hint(
        icon: Icons.travel_explore,
        title: '输入关键词开始搜索',
        subtitle: '点击结果卡片可查看详情并推送到 qB 下载',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final t = _items[i];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TorrentDetailPage(torrent: t))),
          child: _TorrentCard(t: t),
        );
      },
    );
  }
}

class _TorrentCard extends StatelessWidget {
  const _TorrentCard({required this.t});
  final MTeamTorrent t;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(t.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                if (t.isFree)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              const SizedBox(height: 4),
              Text(t.subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _Tag(icon: Icons.storage, text: t.sizeText),
                _Tag(icon: Icons.upload, text: '${t.seeders ?? '-'}'),
                _Tag(icon: Icons.download, text: '${t.leechers ?? '-'}'),
                _Tag(icon: Icons.done_all, text: '${t.snatches ?? '-'}'),
                if (t.createdText != null)
                  _Tag(icon: Icons.schedule, text: t.createdText!),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.white38),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white38),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, height: 1.5)),
          ],
        ),
      ),
    );
  }
}
