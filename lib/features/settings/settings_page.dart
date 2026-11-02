import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/endpoint.dart';
import 'package:pt_pocket/core/network/guardian_client.dart';
import 'package:pt_pocket/core/network/mteam_client.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _lan = TextEditingController();
  final _wan = TextEditingController();
  final _token = TextEditingController();
  final _mteamKey = TextEditingController();
  String _modeStr = 'auto';
  bool _loading = true;

  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  bool _testingMteam = false;
  String? _mteamResult;
  bool _mteamOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var lan = await SecureStore.read(SecureStore.guardianLanUrl);
    final wan = await SecureStore.read(SecureStore.guardianWanUrl);
    final legacy = await SecureStore.read(SecureStore.guardianUrl);
    final token = await SecureStore.read(SecureStore.guardianToken);
    final modeStr = await SecureStore.read(SecureStore.guardianMode);
    final mkey = await SecureStore.read(MTeamClient.storageKey);
    if (!mounted) return;
    setState(() {
      _lan.text = (lan == null || lan.isEmpty) ? (legacy ?? '') : lan;
      _wan.text = wan ?? '';
      _token.text = token ?? '';
      _mteamKey.text = mkey ?? '';
      _modeStr = (modeStr == 'lan' || modeStr == 'wan') ? modeStr : 'auto';
      _loading = false;
    });
  }

  EndpointMode get _mode => switch (_modeStr) {
        'lan' => EndpointMode.lanOnly,
        'wan' => EndpointMode.wanOnly,
        _ => EndpointMode.auto,
      };

  Future<void> _save() async {
    final lan = _lan.text.trim();
    final wan = _wan.text.trim();
    await SecureStore.write(SecureStore.guardianLanUrl, lan);
    await SecureStore.write(SecureStore.guardianWanUrl, wan);
    await SecureStore.write(SecureStore.guardianMode, _modeStr);
    await SecureStore.write(
        SecureStore.guardianUrl, lan.isNotEmpty ? lan : wan); // 兼容旧字段
    ref.read(guardianResolverProvider).reset();
    ref.invalidate(guardianConnProvider);
    ref.invalidate(guardianStatusProvider);
    ref.invalidate(guardianLinkProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存，仪表盘正在按新链路刷新…')));
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    String msg;
    bool ok = false;
    final ep = DualEndpoint(
        lanUrl: _lan.text.trim(), wanUrl: _wan.text.trim(), mode: _mode);
    if (!ep.hasAny) {
      msg = '请至少填写内网或外网地址';
    } else if (_token.text.trim().isEmpty) {
      msg = '请填写令牌 (API_TOKEN)';
    } else {
      final resolver = EndpointResolver(); // 临时实例，不污染全局缓存
      try {
        final first = await resolver.resolve(ep, probePath: '/health');
        try {
          final c = GuardianClient.build(
              GuardianConfig(url: first.url, token: _token.text.trim()));
          await c.pingHealth();
          await c.fetchStatus();
          msg = '✅ ${first.isLan ? "内网" : "外网"}链路可用：${first.url}\n令牌有效，可读取监测状态';
          ok = true;
        } on DioException catch (e1) {
          if (e1.response?.statusCode == 401) {
            msg = '⚠️ 服务在线（${first.url}），但令牌不对（401）';
          } else {
            resolver.reportFailure(first.url);
            try {
              final second = await resolver.resolve(ep, probePath: '/health');
              final c2 = GuardianClient.build(GuardianConfig(
                  url: second.url, token: _token.text.trim()));
              await c2.pingHealth();
              await c2.fetchStatus();
              msg = '✅ 首选链路失败，已自动切换：${second.url}\n令牌有效，可读取监测状态';
              ok = true;
            } catch (e2) {
              msg = '❌ 双链路均失败\n首选: $e1\n备选: $e2';
            }
          }
        } catch (e1) {
          resolver.reportFailure(first.url);
          try {
            final second = await resolver.resolve(ep, probePath: '/health');
            final c2 = GuardianClient.build(
                GuardianConfig(url: second.url, token: _token.text.trim()));
            await c2.pingHealth();
            await c2.fetchStatus();
            msg = '✅ 首选链路失败，已自动切换：${second.url}\n令牌有效，可读取监测状态';
            ok = true;
          } catch (e2) {
            msg = '❌ 双链路均失败\n首选: $e1\n备选: $e2';
          }
        }
      } catch (e) {
        msg = '❌ $e';
      }
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = msg;
      _testOk = ok;
    });
  }

  Future<void> _saveMteam() async {
    await SecureStore.write(MTeamClient.storageKey, _mteamKey.text.trim());
    ref.invalidate(mteamConfigProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('M-Team API Key 已保存')));
  }

  Future<void> _testMteam() async {
    setState(() {
      _testingMteam = true;
      _mteamResult = null;
    });
    final cfg = MTeamConfig(apiKey: _mteamKey.text.trim());
    String msg;
    bool ok;
    try {
      final items = await MTeamClient.build(cfg).search('4K');
      msg = '✅ API Key 有效，搜索正常（返回 ${items.length} 条）';
      ok = true;
    } catch (e) {
      msg = '❌ M-Team 连接失败：$e';
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _testingMteam = false;
      _mteamResult = msg;
      _mteamOk = ok;
    });
  }

  @override
  void dispose() {
    _lan.dispose();
    _wan.dispose();
    _token.dispose();
    _mteamKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('服务连接 · Guardian（双链路）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('自动模式：内网优先，不通自动切换外网（lucky 反代）',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _lan,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '内网地址',
              hintText: 'http://192.168.5.206:45005',
              prefixIcon: Icon(Icons.home_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _wan,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '外网地址（lucky 反代域名）',
              hintText: 'https://ppgd.example.com',
              prefixIcon: Icon(Icons.public),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'auto', label: Text('自动')),
              ButtonSegment(value: 'lan', label: Text('内网')),
              ButtonSegment(value: 'wan', label: Text('外网')),
            ],
            selected: {_modeStr},
            onSelectionChanged: (s) => setState(() => _modeStr = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '令牌 (API_TOKEN)',
              prefixIcon: Icon(Icons.key_outlined),
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
          if (_testResult != null) ...[
            const SizedBox(height: 12),
            Text(_testResult!,
                style: TextStyle(
                    color: _testOk ? Colors.greenAccent : Colors.redAccent)),
          ],
          const SizedBox(height: 28),
          Text('站点凭据 · M-Team',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('控制面板 → 实验室 → API 生成的 Key（仅存在本机安全存储）',
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
                  onPressed: _testingMteam ? null : _testMteam,
                  icon: const Icon(Icons.network_check),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saveMteam,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_mteamResult != null) ...[
            const SizedBox(height: 12),
            Text(_mteamResult!,
                style: TextStyle(
                    color: _mteamOk ? Colors.greenAccent : Colors.redAccent)),
          ],
          const SizedBox(height: 28),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
            child: ListTile(
              leading: Icon(Icons.rocket_launch_outlined),
              title: Text('PT Pocket'),
              subtitle:
                  Text('v0.4.0 · 双链路自动切换\n内网优先 · 断线自动走外网反代'),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}
