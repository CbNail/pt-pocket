import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/proxy_settings.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';

/// 代理设置（需求 13：App 自身网络代理，可填自建旁路由提供的代理服务）。
///
/// 约束（依据 dart:io 的代理实现）：
/// - 只支持 HTTP 代理（`PROXY host:port`）；SOCKS5 不被 Dart 网络栈支持；
/// - 内网 / 本机地址始终直连，只有外网请求才走代理；
/// - 代理密码只存本机安全存储，不写入普通配置。
class ProxySettingsPage extends ConsumerStatefulWidget {
  const ProxySettingsPage({super.key});

  @override
  ConsumerState<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends ConsumerState<ProxySettingsPage> {
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _enabled = false;
  bool _useAuth = false;
  bool _hasPassword = false;
  bool _saving = false;
  bool _testing = false;
  String? _testMessage;

  /// 代理连通性样本：两个公网 HTTPS 地址，取第一个能通的说明代理可用。
  static final List<Uri> _probeTargets = <Uri>[
    Uri.parse('https://api.github.com/'),
    Uri.parse('https://www.baidu.com/'),
  ];

  @override
  void initState() {
    super.initState();
    final ProxySettings settings = ref.read(proxySettingsProvider);
    _enabled = settings.enabled;
    _useAuth = settings.useAuth;
    _host.text = settings.host;
    _port.text = settings.port > 0 ? '${settings.port}' : '';
    _username.text = settings.username;
    ref.read(proxySettingsProvider.notifier).hasPassword().then((bool value) {
      if (mounted) setState(() => _hasPassword = value);
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _validate() {
    final String host = _host.text.trim();
    final int? port = int.tryParse(_port.text.trim());
    if (_enabled && (host.isEmpty || port == null || port <= 0 || port > 65535)) {
      _snack('请填写完整的代理地址与端口（1-65535）');
      return false;
    }
    return true;
  }

  /// 落盘当前表单内容，供「保存代理设置」与「测试代理前自动保存」共用。
  Future<void> _persist() async {
    final String host = _host.text.trim();
    final int? port = int.tryParse(_port.text.trim());
    final String password = _password.text;
    final ProxySettings settings = ProxySettings(
      enabled: _enabled,
      host: host,
      port: port ?? 0,
      useAuth: _useAuth,
      username: _username.text.trim(),
    );
    await ref
        .read(proxySettingsProvider.notifier)
        .save(settings, password: password.isEmpty ? null : password);
    await ref
        .read(proxyRuntimeProvider)
        .update(settings, password: password.isEmpty ? null : password);
    if (!mounted) return;
    setState(() {
      _password.clear();
      if (password.isNotEmpty) _hasPassword = true;
    });
  }

  Future<void> _save() async {
    if (!_validate()) return;
    setState(() => _saving = true);
    await _persist();
    if (!mounted) return;
    setState(() => _saving = false);
    _snack('代理设置已保存并立即生效');
  }

  /// 测试代理：先自动保存当前填写内容，再用该配置发一次真实请求。
  ///
  /// 无论测试成功或失败，配置都已落盘——不必再点一次「保存代理设置」。
  Future<void> _testProxy() async {
    if (!_validate()) return;
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    await _persist();
    if (!mounted) return;
    final String message = await _probeThroughProxy();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testMessage = message;
    });
    _snack('已自动保存代理设置 · $message');
  }

  Future<String> _probeThroughProxy() async {
    final Dio dio = ref.read(proxyRuntimeProvider).createDio(
          connectTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 8),
        );
    final List<String> failures = <String>[];
    for (final Uri target in _probeTargets) {
      try {
        final Response<dynamic> response = await dio.getUri<dynamic>(
          target,
          options: Options(validateStatus: (int? status) => status != null),
        );
        final String via = _enabled ? '经代理' : '代理未启用，本次为直连';
        return '连通：${target.host} 返回 HTTP ${response.statusCode}（$via）';
      } on DioException catch (error) {
        failures.add('${target.host}（${error.type.name}）');
      }
    }
    return '不可达：${failures.join('、')}';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ProxySettings current = ref.watch(proxySettingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('网络代理'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '代理开关',
            subtitle: '开启后本应用访问外网服务时经代理转发',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _enabled,
                  title: const Text('启用代理'),
                  subtitle: Text(current.summary),
                  onChanged: (bool value) => setState(() => _enabled = value),
                ),
                const SizedBox(height: AppSpacing.xs),
                StatusBadge(
                  label: current.isUsable ? '当前已生效' : '当前未生效',
                  tone: current.isUsable ? StatusTone.ok : StatusTone.neutral,
                  compact: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '代理服务',
            subtitle: '填自建旁路由上代理服务的地址与端口（HTTP 代理）',
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '代理地址',
                    hintText: '192.168.1.2',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    hintText: '7890',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '代理认证',
            subtitle: '需要认证时填写用户名与密码',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _useAuth,
                  title: const Text('启用认证'),
                  onChanged: (bool value) => setState(() => _useAuth = value),
                ),
                if (_useAuth) ...<Widget>[
                  TextField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '密码',
                      hintText: _hasPassword ? '已保存，留空表示不修改' : '未保存',
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '密码只保存在本机安全存储，不写入普通配置，也不会提交给服务端。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '连通性检测',
            subtitle: '用当前配置发一次真实请求；测试后自动保存已填内容',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _testing ? null : _testProxy,
                  icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                  label: Text(_testing ? '测试中…' : '测试代理'),
                ),
                if (_testMessage != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_testMessage!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '生效范围与限制',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('· 内网与本机地址（192.168.x、10.x、.local、NAS 内网地址）始终直连，不经过代理。',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpacing.xs),
                Text('· 仅支持 HTTP 代理；Dart 网络栈的代理指令只解析 DIRECT 与 PROXY host:port，不支持 SOCKS5。',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpacing.xs),
                Text('· 代理作用于本应用发起的请求（访问 NAS 服务、站点探测、CookieCloud 拉取）。',
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check, size: AppSizes.iconSm),
            label: Text(_saving ? '保存中…' : '保存代理设置'),
          ),
        ],
      ),
    );
  }
}