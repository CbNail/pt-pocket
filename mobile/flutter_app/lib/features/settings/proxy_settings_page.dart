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

  Future<void> _save() async {
    final String host = _host.text.trim();
    final int? port = int.tryParse(_port.text.trim());
    if (_enabled && (host.isEmpty || port == null || port <= 0 || port > 65535)) {
      _snack('请填写完整的代理地址与端口（1-65535）');
      return;
    }

    final String password = _password.text;
    final ProxySettings settings = ProxySettings(
      enabled: _enabled,
      host: host,
      port: port ?? 0,
      useAuth: _useAuth,
      username: _username.text.trim(),
    );

    setState(() => _saving = true);
    await ref
        .read(proxySettingsProvider.notifier)
        .save(settings, password: password.isEmpty ? null : password);
    await ref
        .read(proxyRuntimeProvider)
        .update(settings, password: password.isEmpty ? null : password);

    if (!mounted) return;
    setState(() {
      _saving = false;
      _password.clear();
      if (password.isNotEmpty) _hasPassword = true;
    });
    _snack('代理设置已保存并立即生效');
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