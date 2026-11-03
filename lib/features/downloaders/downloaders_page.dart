import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/endpoint.dart';
import 'package:pt_pocket/core/push_service.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';

class DownloadersPage extends StatelessWidget {
  const DownloadersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('下载器')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Text('「站点」页推送下载的目标；每台下载器支持内网/外网双链路自动切换',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          SizedBox(height: 16),
          _Section(
              type: DownloaderType.qbittorrent,
              title: 'qBittorrent · WebUI 接口',
              lanHint: 'http://192.168.5.206:8080'),
          SizedBox(height: 28),
          _Section(
              type: DownloaderType.transmission,
              title: 'Transmission · RPC 接口',
              lanHint: 'http://192.168.5.206:9091'),
          SizedBox(height: 28),
          Card(
            child: ListTile(
              leading: Icon(Icons.rocket_launch_outlined),
              title: Text('PT Pocket'),
              subtitle:
                  Text('v0.6.0 · 下载器独立管理\nqB + TR 双链路 · 多目标推送'),
              isThreeLine: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends ConsumerStatefulWidget {
  const _Section(
      {required this.type, required this.title, required this.lanHint});
  final DownloaderType type;
  final String title;
  final String lanHint;

  @override
  ConsumerState<_Section> createState() => _SectionState();
}

class _SectionState extends ConsumerState<_Section> {
  final _name = TextEditingController();
  final _lan = TextEditingController();
  final _wan = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _path = TextEditingController();
  String _modeStr = 'auto';
  bool _loading = true;
  bool _testing = false;
  String? _result;
  bool _ok = false;

  String get _kName =>
      widget.type == DownloaderType.qbittorrent ? SecureStore.qbName : SecureStore.trName;
  String get _kLan =>
      widget.type == DownloaderType.qbittorrent ? SecureStore.qbLanUrl : SecureStore.trLanUrl;
  String get _kWan =>
      widget.type == DownloaderType.qbittorrent ? SecureStore.qbWanUrl : SecureStore.trWanUrl;
  String get _kMode =>
      widget.type == DownloaderType.qbittorrent ? SecureStore.qbMode : SecureStore.trMode;
  String get _kUser =>
      widget.type == DownloaderType.qbittorrent ? SecureStore.qbUsername : SecureStore.trUsername;
  String get _kPass =>
      widget.type == DownloaderType.qbittorrent ? SecureStore.qbPassword : SecureStore.trPassword;
  String get _kPath =>
      widget.type == DownloaderType.qbittorrent ? SecureStore.qbPath : SecureStore.trPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = await SecureStore.read(_kName);
    final lan = await SecureStore.read(_kLan);
    final wan = await SecureStore.read(_kWan);
    final mode = await SecureStore.read(_kMode);
    final user = await SecureStore.read(_kUser);
    final pass = await SecureStore.read(_kPass);
    final path = await SecureStore.read(_kPath);
    if (!mounted) return;
    setState(() {
      _name.text = name ?? '';
      _lan.text = lan ?? '';
      _wan.text = wan ?? '';
      _user.text = user ?? '';
      _pass.text = pass ?? '';
      _path.text = path ?? '';
      _modeStr = (mode == 'lan' || mode == 'wan') ? mode : 'auto';
      _loading = false;
    });
  }

  EndpointMode get _mode => switch (_modeStr) {
        'lan' => EndpointMode.lanOnly,
        'wan' => EndpointMode.wanOnly,
        _ => EndpointMode.auto,
      };

  DownloaderRuntime get _runtime {
    final lan = _lan.text.trim();
    final wan = _wan.text.trim();
    final fallback =
        widget.type == DownloaderType.qbittorrent ? 'qBittorrent' : 'Transmission';
    return DownloaderRuntime(
      id: widget.type == DownloaderType.qbittorrent ? 'qb' : 'tr',
      type: widget.type,
      name: _name.text.trim().isEmpty ? fallback : _name.text.trim(),
      endpoint: DualEndpoint(
        lanUrl: lan.isEmpty ? null : lan,
        wanUrl: wan.isEmpty ? null : wan,
        mode: _mode,
      ),
      username: _user.text.trim(),
      password: _pass.text.trim(),
      defaultPath: _path.text.trim().isEmpty ? null : _path.text.trim(),
    );
  }

  Future<void> _save({String? tip}) async {
    await SecureStore.write(_kName, _name.text.trim());
    await SecureStore.write(_kLan, _lan.text.trim());
    await SecureStore.write(_kWan, _wan.text.trim());
    await SecureStore.write(_kMode, _modeStr);
    await SecureStore.write(_kUser, _user.text.trim());
    await SecureStore.write(_kPass, _pass.text.trim());
    await SecureStore.write(_kPath, _path.text.trim());
    ref.invalidate(downloadersProvider);
    if (!mounted || tip == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(tip)));
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    String msg;
    bool ok = false;
    final rt = _runtime;
    if (rt.endpoint.lanUrl == null && rt.endpoint.wanUrl == null) {
      msg = '请至少填写内网或外网地址';
    } else if (rt.username.isEmpty || rt.password.isEmpty) {
      msg = '请填写账号和密码';
    } else {
      try {
        msg = await testDownloader(rt);
        ok = true;
      } catch (e) {
        msg = '❌ $e';
      }
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = msg;
      _ok = ok;
    });
    if (ok) await _save(tip: '${widget.title} 配置已保存');
  }

  @override
  void dispose() {
    _name.dispose();
    _lan.dispose();
    _wan.dispose();
    _user.dispose();
    _pass.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: '名称（显示用）', prefixIcon: Icon(Icons.label_outline)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lan,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                  labelText: '内网地址',
                  hintText: widget.lanHint,
                  prefixIcon: const Icon(Icons.home_outlined)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _wan,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: '外网地址（lucky 反代域名）',
                  prefixIcon: Icon(Icons.public)),
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
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                      labelText: '账号', prefixIcon: Icon(Icons.person_outline)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: '密码', prefixIcon: Icon(Icons.lock_outline)),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _path,
              decoration: const InputDecoration(
                  labelText: '默认保存路径（推送时可临时修改）',
                  hintText: '/mnt/qnap/24download',
                  prefixIcon: Icon(Icons.folder_outlined)),
            ),
            const SizedBox(height: 14),
            Row(children: [
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
            ]),
            if (_result != null) ...[
              const SizedBox(height: 10),
              Text(_result!,
                  style: TextStyle(
                      color: _ok ? Colors.greenAccent : Colors.redAccent,
                      height: 1.4)),
            ],
          ],
        ),
      ),
    );
  }
}
