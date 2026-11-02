import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/endpoint.dart';
import 'package:pt_pocket/core/network/guardian_client.dart';
import 'package:pt_pocket/core/network/qb_client.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  // Guardian
  final _lan = TextEditingController();
  final _wan = TextEditingController();
  final _token = TextEditingController();
  String _modeStr = 'auto';
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  // qBittorrent
  final _qbLan = TextEditingController();
  final _qbWan = TextEditingController();
  final _qbUser = TextEditingController();
  final _qbPass = TextEditingController();
  String _qbModeStr = 'auto';
  bool _testingQb = false;
  String? _qbResult;
  bool _qbOk = false;

  bool _loading = true;

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
    final qbLan = await SecureStore.read(SecureStore.qbLanUrl);
    final qbWan = await SecureStore.read(SecureStore.qbWanUrl);
    final qbModeStr = await SecureStore.read(SecureStore.qbMode);
    final qbUser = await SecureStore.read(SecureStore.qbUsername);
    final qbPass = await SecureStore.read(SecureStore.qbPassword);
    if (!mounted) return;
    String mode = 'auto';
    if (modeStr == 'lan') mode = 'lan';
    if (modeStr == 'wan') mode = 'wan';
    String qbMode = 'auto';
    if (qbModeStr == 'lan') qbMode = 'lan';
    if (qbModeStr == 'wan') qbMode = 'wan';
    setState(() {
      _lan.text = (lan == null || lan.isEmpty) ? (legacy ?? '') : lan;
      _wan.text = wan ?? '';
      _token.text = token ?? '';
      _modeStr = mode;
      _qbLan.text = qbLan ?? '';
      _qbWan.text = qbWan ?? '';
      _qbUser.text = qbUser ?? '';
      _qbPass.text = qbPass ?? '';
      _qbModeStr = qbMode;
      _loading = false;
    });
  }

  EndpointMode get _mode => switch (_modeStr) {
        'lan' => EndpointMode.lanOnly,
        'wan' => EndpointMode.wanOnly,
        _ => EndpointMode.auto,
      };

  EndpointMode get _qbMode => switch (_qbModeStr) {
        'lan' => EndpointMode.lanOnly,
        'wan' => EndpointMode.wanOnly,
        _ => EndpointMode.auto,
      };

  Future<void> _save({String? tip}) async {
    final lan = _lan.text.trim();
    final wan = _wan.text.trim();
    await SecureStore.write(SecureStore.guardianLanUrl, lan);
    await SecureStore.write(SecureStore.guardianWanUrl, wan);
    await SecureStore.write(SecureStore.guardianMode, _modeStr);
    await SecureStore.write(SecureStore.guardianToken, _token.text.trim());
    await SecureStore.write(
        SecureStore.guardianUrl, lan.isNotEmpty ? lan : wan);
    ref.read(guardianResolverProvider).reset();
    ref.invalidate(guardianConnProvider);
    ref.invalidate(guardianStatusProvider);
    ref.invalidate(guardianLinkProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tip ?? '已保存')));
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
      final resolver = EndpointResolver();
      try {
        final first = await resolver.resolve(ep, probePath: '/health');
        try {
          final c = GuardianClient.build(
              GuardianConfig(url: first.url, token: _token.text.trim()));
          await c.pingHealth();
          await c.fetchStatus();
          msg =
              '✅ ${first.isLan ? "内网" : "外网"}链路可用：${first.url}\n令牌有效 · 已自动保存';
          ok = true;
        } catch (e1) {
          resolver.reportFailure(first.url);
          try {
            final second = await resolver.resolve(ep, probePath: '/health');
            final c2 = GuardianClient.build(
                GuardianConfig(url: second.url, token: _token.text.trim()));
            await c2.pingHealth();
            await c2.fetchStatus();
            msg = '✅ 首选链路失败，已自动切换：${second.url}\n令牌有效 · 已自动保存';
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
    if (ok) await _save(tip: 'Guardian 配置已保存（含令牌），仪表盘刷新中…');
  }

  Future<void> _saveQb({String? tip}) async {
    await SecureStore.write(SecureStore.qbLanUrl, _qbLan.text.trim());
    await SecureStore.write(SecureStore.qbWanUrl, _qbWan.text.trim());
    await SecureStore.write(SecureStore.qbMode, _qbModeStr);
    await SecureStore.write(SecureStore.qbUsername, _qbUser.text.trim());
    await SecureStore.write(SecureStore.qbPassword, _qbPass.text.trim());
    ref.read(qbResolverProvider).reset();
    ref.invalidate(qbConnProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tip ?? 'qB 配置已保存')));
  }

  Future<void> _testQb() async {
    setState(() {
      _testingQb = true;
      _qbResult = null;
    });
    String msg;
    bool ok = false;
    final ep = DualEndpoint(
        lanUrl: _qbLan.text.trim(), wanUrl: _qbWan.text.trim(), mode: _qbMode);
    if (!ep.hasAny) {
      msg = '请至少填写内网或外网地址';
    } else if (_qbUser.text.trim().isEmpty || _qbPass.text.trim().isEmpty) {
      msg = '请填写 qB 用户名和密码';
    } else {
      final resolver = EndpointResolver();
      Future<String> attempt() async {
        final r =
            await resolver.resolve(ep, probePath: '/api/v2/app/version');
        try {
          final c = QbClient.build(
              baseUrl: r.url,
              username: _qbUser.text.trim(),
              password: _qbPass.text.trim());
          await c.login();
          final v = await c.version();
          return '${r.isLan ? "内网" : "外网"}链路可用：${r.url}\nqB v$v';
        } catch (e) {
          resolver.reportFailure(r.url);
          rethrow;
        }
      }

      try {
        msg = '✅ ${await attempt()}\n已自动保存';
        ok = true;
      } catch (e1) {
        try {
          msg = '✅ 首选链路失败，已自动切换\n${await attempt()}\n已自动保存';
          ok = true;
        } catch (e2) {
          msg = '❌ 双链路均失败\n首选: $e1\n备选: $e2';
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _testingQb = false;
      _qbResult = msg;
      _qbOk = ok;
    });
    if (ok) await _saveQb(tip: 'qBittorrent 配置已保存');
  }

  @override
  void dispose() {
    _lan.dispose();
    _wan.dispose();
    _token.dispose();
    _qbLan.dispose();
    _qbWan.dispose();
    _qbUser.dispose();
    _qbPass.dispose();
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
          const Text('自动模式：内网优先，不通自动切换外网（lucky 反代）\n站点凭据请在「站点」页右上角 ⚙ 的站点管理里配置',
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
          Text('服务连接 · qBittorrent（双链路）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('「站点」页种子详情的「推送到 qB」会把磁力链发到这里开始下载',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _qbLan,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '内网地址',
              hintText: 'http://192.168.5.206:8080',
              prefixIcon: Icon(Icons.home_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _qbWan,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '外网地址（lucky 反代域名）',
              hintText: 'https://ppqb.example.com',
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
            selected: {_qbModeStr},
            onSelectionChanged: (s) => setState(() => _qbModeStr = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _qbUser,
            decoration: const InputDecoration(
              labelText: 'WebUI 用户名',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _qbPass,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'WebUI 密码',
              prefixIcon: Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _testingQb ? null : _testQb,
                  icon: const Icon(Icons.network_check),
                  label: const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saveQb,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_qbResult != null) ...[
            const SizedBox(height: 12),
            Text(_qbResult!,
                style: TextStyle(
                    color: _qbOk ? Colors.greenAccent : Colors.redAccent)),
          ],
          const SizedBox(height: 28),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
            child: ListTile(
              leading: Icon(Icons.rocket_launch_outlined),
              title: Text('PT Pocket'),
              subtitle: Text(
                  'v0.5.0 · 搜索→详情→一键推送 qB\nGuardian 监护 + 双链路自动切换'),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}
