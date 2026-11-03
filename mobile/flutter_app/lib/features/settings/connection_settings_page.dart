import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/network/endpoint_resolver.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';

/// 连接与服务：内网 / 外网（lucky 反代）双通道地址与自动切换策略（需求 16）。
///
/// 外网地址填 lucky 反代后的入口；自动模式下内网优先（2 秒探测），
/// 失败回退外网（10 秒探测），回到家网后下次请求自动切回内网。
class ConnectionSettingsPage extends ConsumerStatefulWidget {
  const ConnectionSettingsPage({super.key});

  @override
  ConsumerState<ConnectionSettingsPage> createState() => _ConnectionSettingsPageState();
}

class _ConnectionSettingsPageState extends ConsumerState<ConnectionSettingsPage> {
  final TextEditingController _lan = TextEditingController();
  final TextEditingController _wan = TextEditingController();

  LinkMode _mode = LinkMode.auto;
  bool? _lanOk;
  bool? _wanOk;
  bool _testing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final EndpointProfile profile = ref.read(endpointProfileProvider);
    _lan.text = profile.lanBaseUrl?.toString() ?? '';
    _wan.text = profile.wanBaseUrl?.toString() ?? '';
    _mode = profile.mode;
  }

  @override
  void dispose() {
    _lan.dispose();
    _wan.dispose();
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

  Future<void> _testBoth() async {
    final Uri? lan = EndpointProfileNotifier.parseBaseUrl(_lan.text);
    final Uri? wan = EndpointProfileNotifier.parseBaseUrl(_wan.text);
    if (lan == null && wan == null) {
      _snack('请先填写内网或外网地址');
      return;
    }
    setState(() {
      _testing = true;
      _lanOk = null;
      _wanOk = null;
    });

    final HttpHealthProbe probe = ref.read(healthProbeProvider);
    final bool? lanOk = lan == null ? null : await probe(lan, AppConfig.lanProbeTimeout);
    final bool? wanOk = wan == null ? null : await probe(wan, AppConfig.wanProbeTimeout);

    if (!mounted) return;
    setState(() {
      _testing = false;
      _lanOk = lanOk;
      _wanOk = wanOk;
    });
    // 手工测试后让选路缓存失效，下一次请求按最新结果重新选路。
    ref.read(endpointResolverProvider).invalidate();
  }

  Future<void> _save() async {
    final Uri? lan = EndpointProfileNotifier.parseBaseUrl(_lan.text);
    final Uri? wan = EndpointProfileNotifier.parseBaseUrl(_wan.text);
    if (_lan.text.trim().isNotEmpty && (lan == null || lan.host.isEmpty)) {
      _snack('内网地址格式不正确');
      return;
    }
    if (_wan.text.trim().isNotEmpty && (wan == null || wan.host.isEmpty)) {
      _snack('外网地址格式不正确');
      return;
    }

    setState(() => _saving = true);
    await ref.read(endpointProfileProvider.notifier).update(
          lan: lan,
          wan: wan,
          mode: _mode,
          clearLan: _lan.text.trim().isEmpty,
          clearWan: _wan.text.trim().isEmpty,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    _snack('连接设置已保存，下一次请求按新配置选路');
  }

  Widget _probeBadge(bool? state) {
    if (_testing) {
      return const StatusBadge(label: '检测中', tone: StatusTone.neutral, compact: true);
    }
    if (state == null) {
      return const StatusBadge(label: '未检测', tone: StatusTone.neutral, compact: true);
    }
    return StatusBadge(
      label: state ? '可用' : '不可用',
      tone: state ? StatusTone.ok : StatusTone.danger,
      icon: state ? Icons.check_circle_outline : Icons.error_outline,
      compact: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('连接与服务'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '服务地址',
            subtitle: '外网地址填 lucky 反代后的入口；留空表示不使用该通道',
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _lan,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '内网地址',
                    hintText: 'http://192.168.1.10:8000',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _wan,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '外网地址',
                    hintText: 'https://pt.example.com',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '链路模式',
            subtitle: '自动模式：内网优先，失败回退外网；回到家网自动切回内网',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<LinkMode>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<LinkMode>>[
                      ButtonSegment<LinkMode>(value: LinkMode.auto, label: Text('自动')),
                      ButtonSegment<LinkMode>(value: LinkMode.lan, label: Text('仅内网')),
                      ButtonSegment<LinkMode>(value: LinkMode.wan, label: Text('仅外网')),
                    ],
                    selected: <LinkMode>{_mode},
                    onSelectionChanged: (Set<LinkMode> selection) =>
                        setState(() => _mode = selection.first),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '自动模式探测超时：内网 ${AppConfig.lanProbeTimeout.inSeconds} 秒、'
                  '外网 ${AppConfig.wanProbeTimeout.inSeconds} 秒；成功选路缓存 '
                  '${AppConfig.endpointCacheTtl.inMinutes} 分钟，网络切换或请求失败会立即失效重选。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '连通性检测',
            subtitle: '以 API 健康检查为准，而不是仅能建立 TCP 连接',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    SizedBox(width: 72, child: Text('内网', style: theme.textTheme.bodyMedium)),
                    _probeBadge(_lanOk),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: <Widget>[
                    SizedBox(width: 72, child: Text('外网', style: theme.textTheme.bodyMedium)),
                    _probeBadge(_wanOk),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.tonalIcon(
                  onPressed: _testing ? null : _testBoth,
                  icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                  label: Text(_testing ? '检测中…' : '测试两条通道'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check, size: AppSizes.iconSm),
            label: Text(_saving ? '保存中…' : '保存连接设置'),
          ),
        ],
      ),
    );
  }
}