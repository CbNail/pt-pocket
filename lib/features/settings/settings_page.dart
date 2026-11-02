import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/guardian_client.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _loading = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await SecureStore.read(SecureStore.guardianUrl);
    final token = await SecureStore.read(SecureStore.guardianToken);
    if (!mounted) return;
    setState(() {
      _url.text = url ?? '';
      _token.text = token ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    await SecureStore.write(SecureStore.guardianUrl, _url.text.trim());
    await SecureStore.write(SecureStore.guardianToken, _token.text.trim());
    ref.invalidate(guardianConfigProvider);
    ref.invalidate(guardianStatusProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存，仪表盘正在刷新…')));
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final cfg =
        GuardianConfig(url: _url.text.trim(), token: _token.text.trim());
    final client = GuardianClient.build(cfg);
    String msg;
    bool ok;
    try {
      await client.pingHealth();
      try {
        await client.fetchStatus();
        msg = '✅ 服务在线，令牌有效，已能读取监测状态';
        ok = true;
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) {
          msg = '⚠️ 服务在线，但令牌不对（401）';
        } else {
          msg = '⚠️ 服务在线，但读取状态失败：${e.message}';
        }
        ok = false;
      }
    } catch (e) {
      msg = '❌ 连不上 Guardian：$e';
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = msg;
      _testOk = ok;
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
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
          Text('服务连接', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('PT Pocket ↔ 服务器上的各服务',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Guardian 地址',
              hintText: 'http://192.168.5.206:45005',
              prefixIcon: Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Guardian 令牌 (API_TOKEN)',
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
          const SizedBox(height: 24),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
            child: ListTile(
              leading: Icon(Icons.rocket_launch_outlined),
              title: Text('PT Pocket'),
              subtitle:
                  Text('v0.2.0 · Day1 骨架\nGuardian 连接已可用，站点中心施工中'),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}
