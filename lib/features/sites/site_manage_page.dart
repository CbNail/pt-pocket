import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';

/// 站点管理：各站点凭据集中在这里（M-Team 已支持，后续逐站扩展）
class SiteManagePage extends ConsumerStatefulWidget {
  const SiteManagePage({super.key});

  @override
  ConsumerState<SiteManagePage> createState() => _SiteManagePageState();
}

class _SiteManagePageState extends ConsumerState<SiteManagePage> {
  final _mteamKey = TextEditingController();
  bool _loading = true;
  bool _testing = false;
  String? _result;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = await SecureStore.read(MTeamClient.storageKey);
    if (!mounted) return;
    setState(() {
      _mteamKey.text = key ?? '';
      _loading = false;
    });
  }

  Future<void> _save({String? tip}) async {
    await SecureStore.write(MTeamClient.storageKey, _mteamKey.text.trim());
    ref.invalidate(mteamConfigProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tip ?? 'M-Team API Key 已保存')));
  }

  /// 测试成功即自动保存
  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final key = _mteamKey.text.trim();
    if (key.isEmpty) {
      setState(() {
        _testing = false;
        _result = '请先粘贴 API Key';
        _ok = false;
      });
      return;
    }
    String msg;
    bool ok;
    try {
      final items =
          await MTeamClient.build(MTeamConfig(apiKey: key)).search('4K');
      msg = '✅ API Key 有效，搜索正常（返回 ${items.length} 条）· 已自动保存';
      ok = true;
    } catch (e) {
      msg = '❌ M-Team 连接失败：$e';
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = msg;
      _ok = ok;
    });
    if (ok) await _save();
  }

  @override
  void dispose() {
    _mteamKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('站点管理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('M-Team（馒头）', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('获取路径：控制台 → 实验室 → 存取令牌\n仅存在本机安全存储，不上传任何服务器',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _mteamKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'M-Team API Key',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.network_check),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_result != null) ...[
            const SizedBox(height: 12),
            Text(_result!,
                style: TextStyle(
                    color: _ok ? Colors.greenAccent : Colors.redAccent)),
          ],
          const SizedBox(height: 28),
          Card(
            child: ListTile(
              leading: Icon(Icons.more_horiz, color: Colors.white38),
              title: Text('更多站点',
                  style: TextStyle(color: Colors.white38)),
              subtitle: Text('HDHome 等 Cookie 型站点接入中\n（PTD 备份导入将在这里完成）',
                  style: TextStyle(color: Colors.white24)),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}
