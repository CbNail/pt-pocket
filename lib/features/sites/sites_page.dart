import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/push_service.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
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
  Set<String> _favs = {};

  @override
  void initState() {
    super.initState();
    _loadFavs();
  }

  Future<void> _loadFavs() async {
    final raw = await SecureStore.read(SecureStore.favIds);
    if (!mounted) return;
    setState(() =>
        _favs = (raw ?? '').split(',').where((s) => s.isNotEmpty).toSet());
  }

  Future<void> _toggleFav(MTeamTorrent t) async {
    final set = {..._favs};
    if (!set.add(t.id)) set.remove(t.id);
    setState(() => _favs = set);
    await SecureStore.write(SecureStore.favIds, set.join(','));
  }

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

  /// 快捷推送（列表长按/左滑）：genDLink → pushToDownloader
  Future<void> _quickPush(MTeamTorrent t, DownloaderRuntime? d) async {
    final messenger = ScaffoldMessenger.of(context);
    if (d == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('还未配置下载器：到「下载器」标签页添加并保存')));
      return;
    }
    final cfg = await ref.read(mteamConfigProvider.future);
    if (cfg == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('还未配置 M-Team API Key：站点页 ⚙ → 站点管理')));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('① 获取下载链接…')));
    String magnet;
    try {
      magnet = await MTeamClient.build(cfg).genDLink(t.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('❌ 获取下载链接失败：$e')));
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text('② 推送到 ${d.name}…')));
    try {
      final used = await pushToDownloader(
          dl: d, magnet: magnet, savePath: d.defaultPath);
      messenger.showSnackBar(
          SnackBar(content: Text('✅ 已推送到 ${d.name}（$used）')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('❌ 推送失败：$e')));
    }
  }

  void _showPushSheet(MTeamTorrent t) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => Consumer(
        builder: (context, ref, _) =>
            ref.watch(downloadersProvider).when(
          loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text('加载下载器失败：$e')),
          data: (dls) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Text('推送到…',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                if (dls.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(24),
                      child:
                          Text('还未配置下载器：到「下载器」标签页添加')),
                for (final d in dls)
                  ListTile(
                    leading: Icon(
                        d.type == DownloaderType.qbittorrent
                            ? Icons.grid_view_outlined
                            : Icons.swap_horiz),
                    title: Text(d.name),
                    subtitle: Text(d.defaultPath ?? '默认下载目录',
                        style: const TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.arrow_forward_ios,
                        size: 14),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _quickPush(t, d);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
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
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const SiteManagePage())),
          ),
        ],
      ),
      body: Column(children: [
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
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('单击详情 · 长按选下载器推送 · 左滑下载/收藏',
                style: TextStyle(color: Colors.white24, fontSize: 11)),
          ),
        ),
        Expanded(child: _buildBody()),
      ]),
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
      return _Hint(icon: Icons.cloud_off_outlined, title: '搜索失败', subtitle: '$_error');
    }
    if (_items.isEmpty) {
      return const _Hint(
        icon: Icons.travel_explore,
        title: '输入关键词开始搜索',
        subtitle: '结果支持详情推送、快捷推送与收藏',
      );
    }
    return SlidableAutoCloseBehavior(
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final t = _items[i];
          return Slidable(
            key: ValueKey('sl-${t.id}'),
            groupTag: 'sites',
            endActionPane: ActionPane(
              motion: const BehindMotion(),
              extentRatio: 0.45,
              children: [
                SlidableAction(
                  onPressed: (ctx) {
                    Slidable.of(ctx)?.close();
                    _quickPush(t, null); // 用第一台已配置下载器，可长按另选
                  },
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                  icon: Icons.download,
                  label: '下载',
                ),
                SlidableAction(
                  onPressed: (ctx) {
                    Slidable.of(ctx)?.close();
                    _toggleFav(t);
                  },
                  backgroundColor: Colors.amber.shade700,
                  foregroundColor: Colors.white,
                  icon: Icons.favorite,
                  label: _favs.contains(t.id) ? '取消' : '收藏',
                ),
              ],
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TorrentDetailPage(torrent: t))),
              onLongPress: () => _showPushSheet(t),
              child: _TorrentCard(t: t, fav: _favs.contains(t.id)),
            ),
          );
        },
      ),
    );
  }
}

class _TorrentCard extends StatelessWidget {
  const _TorrentCard({required this.t, this.fav = false});
  final MTeamTorrent t;
  final bool fav;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
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
                if (fav)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(Icons.favorite,
                        size: 16, color: Colors.pinkAccent),
                  ),
                if (t.isFree)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
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
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 13)),
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: Colors.white38),
      const SizedBox(width: 4),
      Text(text,
          style: const TextStyle(fontSize: 12, color: Colors.white70)),
    ]);
  }
}

class _Hint extends StatelessWidget {
  const _Hint(
      {required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: Colors.white38),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, height: 1.5)),
        ]),
      ),
    );
  }
}
