import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/network/address_probe_controller.dart';
import '../../core/network/endpoint_resolver.dart';
import '../../core/network/url_utils.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/storage/probe_result_store.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/address_field.dart';
import '../../shared/widgets/channel_switch.dart';
import '../../shared/widgets/section_card.dart';

/// 连接与服务：内网 / 外网（lucky 反代）双通道地址、链路模式与实时连通性（需求 16）。
///
/// 本轮改造要点：
/// - 地址按「协议点选 + 主机 + 端口」分开录入，端口有默认值且可改，粘贴整条 URL 会自动拆分；
/// - 地址填完即自动探测，地址后直接给出连通标记；
/// - 两条通道**分开检测**，整体连通情况汇总在「服务地址」框底部；
/// - 探测结果落盘，重新进入页面会按已存地址实时重测，不再固定显示「未检测」。
class ConnectionSettingsPage extends ConsumerStatefulWidget {
  const ConnectionSettingsPage({super.key});

  @override
  ConsumerState<ConnectionSettingsPage> createState() => _ConnectionSettingsPageState();
}

class _ConnectionSettingsPageState extends ConsumerState<ConnectionSettingsPage> {
  static const String _lanKey = 'endpoint.lan';
  static const String _wanKey = 'endpoint.wan';

  final TextEditingController _lanHost = TextEditingController();
  final TextEditingController _lanPort = TextEditingController();
  final TextEditingController _wanHost = TextEditingController();
  final TextEditingController _wanPort = TextEditingController();

  String _lanScheme = 'http';
  String _wanScheme = 'https';
  LinkMode _mode = LinkMode.auto;

  /// 当前展示的通道：0 内网 / 1 外网（一次只显示一条，避免两栏并排）。
  int _activeChannel = 0;
  bool _saving = false;

  late final AddressProbeController _lanProbes;
  late final AddressProbeController _wanProbes;

  @override
  void initState() {
    super.initState();
    final EndpointProfile profile = ref.read(endpointProfileProvider);
    _fillFrom(profile.lanBaseUrl, isLan: true);
    _fillFrom(profile.wanBaseUrl, isLan: false);
    _mode = profile.mode;

    final ProbeResultStore store = ref.read(probeResultStoreProvider);
    _lanProbes = AddressProbeController(
      store: store,
      probe: _healthProbe,
      timeout: AppConfig.lanProbeTimeout,
    )..addListener(_onProbeChanged);
    _wanProbes = AddressProbeController(
      store: store,
      probe: _healthProbe,
      timeout: AppConfig.wanProbeTimeout,
    )..addListener(_onProbeChanged);

    // 进页面就按已存地址实测两条通道：状态实时，而不是固定「未检测」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reprobeAll();
    });
  }

  @override
  void dispose() {
    _lanHost.dispose();
    _lanPort.dispose();
    _wanHost.dispose();
    _wanPort.dispose();
    _lanProbes.dispose();
    _wanProbes.dispose();
    super.dispose();
  }

  Future<ProbeSnapshot> _healthProbe(Uri target, Duration timeout) async =>
      snapshotFromHealth(await ref.read(healthProbeProvider).diagnose(target, timeout), target);

  void _onProbeChanged() {
    if (mounted) setState(() {});
  }

  void _fillFrom(Uri? uri, {required bool isLan}) {
    final AddressParts parts =
        uri == null ? const AddressParts() : UrlUtils.split(uri.toString());
    if (isLan) {
      _lanScheme = parts.isEmpty ? 'http' : parts.scheme;
      _lanHost.text = parts.host;
      _lanPort.text = parts.isEmpty ? '${UrlUtils.defaultPort(_lanScheme)}' : parts.portText;
    } else {
      _wanScheme = parts.isEmpty ? 'https' : parts.scheme;
      _wanHost.text = parts.host;
      _wanPort.text = parts.isEmpty ? '${UrlUtils.defaultPort(_wanScheme)}' : parts.portText;
    }
  }

  Uri? get _lanUri =>
      UrlUtils.compose(scheme: _lanScheme, host: _lanHost.text, port: _lanPort.text);
  Uri? get _wanUri =>
      UrlUtils.compose(scheme: _wanScheme, host: _wanHost.text, port: _wanPort.text);

  bool get _checking => _lanProbes.isProbing(_lanKey) || _wanProbes.isProbing(_wanKey);

  bool get _lanConfigured => _lanHost.text.trim().isNotEmpty;
  bool get _wanConfigured => _wanHost.text.trim().isNotEmpty;

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

  /// 录入过程中的延时探测：只刷新状态，不落盘配置。
  void _scheduleProbe({required bool isLan}) {
    if (isLan) {
      _lanProbes.schedule(_lanKey, _lanConfigured ? _lanUri : null);
    } else {
      _wanProbes.schedule(_wanKey, _wanConfigured ? _wanUri : null);
    }
  }

  /// 立即探测两条通道（进页面与点「重新检测」时用）。
  Future<void> _reprobeAll() async {
    await Future.wait<void>(<Future<void>>[
      if (_lanConfigured) _lanProbes.probeNow(_lanKey, _lanUri),
      if (_wanConfigured) _wanProbes.probeNow(_wanKey, _wanUri),
    ]);
  }

  Future<void> _persistProfile() async {
    await ref.read(endpointProfileProvider.notifier).update(
          lan: _lanUri,
          wan: _wanUri,
          mode: _mode,
          clearLan: !_lanConfigured,
          clearWan: !_wanConfigured,
        );
    ref.read(endpointResolverProvider).invalidate();
  }

  Future<void> _testBoth() async {
    if (_lanConfigured && _lanUri == null) {
      _snack('内网主机或端口不正确，请检查');
      return;
    }
    if (_wanConfigured && _wanUri == null) {
      _snack('外网主机或端口不正确，请检查');
      return;
    }
    if (!_lanConfigured && !_wanConfigured) {
      _snack('请先填写内网或外网地址');
      return;
    }

    await _reprobeAll();
    // 需求：测试后自动保存，无论成功或失败。
    await _persistProfile();
    if (!mounted) return;
    _snack(
      '已自动保存连接设置 · 内网${AddressPairSummary.describe(
        AddressSummaryItem(
          name: '内网',
          configured: _lanConfigured,
          snapshot: _lanProbes.snapshot(_lanKey),
        ),
      )} / 外网${AddressPairSummary.describe(
        AddressSummaryItem(
          name: '外网',
          configured: _wanConfigured,
          snapshot: _wanProbes.snapshot(_wanKey),
        ),
      )}',
    );
  }

  Future<void> _save() async {
    if (_lanConfigured && _lanUri == null) {
      _snack('内网主机或端口不正确，请检查');
      return;
    }
    if (_wanConfigured && _wanUri == null) {
      _snack('外网主机或端口不正确，请检查');
      return;
    }
    setState(() => _saving = true);
    await _persistProfile();
    if (!mounted) return;
    setState(() => _saving = false);
    _snack('连接设置已保存，下一次请求按新配置选路');
  }

  /// 当前实际优先使用的通道（供底部整体情况展示）。
  String _activeLabel() {
    if (_mode == LinkMode.lan) return '内网（仅内网模式）';
    if (_mode == LinkMode.wan) return '外网（仅外网模式）';
    if (_lanProbes.snapshot(_lanKey)?.usable ?? false) return '内网';
    if (_wanProbes.snapshot(_wanKey)?.usable ?? false) return '外网';
    return '';
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
            subtitle: '协议点选、主机与端口分开填；左侧切换内网 / 外网，填完即自动检测，整体情况在最下方',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ChannelSwitch(
                  index: _activeChannel,
                  onIndexChanged: (int value) => setState(() => _activeChannel = value),
                  panes: <ChannelPane>[
                    ChannelPane(
                      label: '内网',
                      configured: _lanConfigured,
                      snapshot: _lanProbes.snapshot(_lanKey),
                      probing: _lanProbes.isProbing(_lanKey),
                      child: AddressInput(
                        label: '内网地址',
                        keyPrefix: 'endpoint.lan',
                        scheme: _lanScheme,
                        hostController: _lanHost,
                        portController: _lanPort,
                        onSchemeChanged: (String value) => setState(() => _lanScheme = value),
                        snapshot: _lanProbes.snapshot(_lanKey),
                        probing: _lanProbes.isProbing(_lanKey),
                        hostHint: '192.168.1.10',
                        onEdited: () => _scheduleProbe(isLan: true),
                        onSubmitted: () => _lanProbes.probeNow(_lanKey, _lanUri),
                      ),
                    ),
                    ChannelPane(
                      label: '外网',
                      configured: _wanConfigured,
                      snapshot: _wanProbes.snapshot(_wanKey),
                      probing: _wanProbes.isProbing(_wanKey),
                      child: AddressInput(
                        label: '外网地址',
                        keyPrefix: 'endpoint.wan',
                        scheme: _wanScheme,
                        hostController: _wanHost,
                        portController: _wanPort,
                        onSchemeChanged: (String value) => setState(() => _wanScheme = value),
                        snapshot: _wanProbes.snapshot(_wanKey),
                        probing: _wanProbes.isProbing(_wanKey),
                        hostHint: 'pt.example.com',
                        onEdited: () => _scheduleProbe(isLan: false),
                        onSubmitted: () => _wanProbes.probeNow(_wanKey, _wanUri),
                      ),
                    ),
                  ],
                ),
                const Divider(height: AppSpacing.xl),
                AddressPairSummary(
                  items: <AddressSummaryItem>[
                    AddressSummaryItem(
                      name: '内网',
                      configured: _lanConfigured,
                      snapshot: _lanProbes.snapshot(_lanKey),
                      probing: _lanProbes.isProbing(_lanKey),
                    ),
                    AddressSummaryItem(
                      name: '外网',
                      configured: _wanConfigured,
                      snapshot: _wanProbes.snapshot(_wanKey),
                      probing: _wanProbes.isProbing(_wanKey),
                    ),
                  ],
                  activeLabel: _activeLabel(),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.tonalIcon(
                  onPressed: _checking ? null : _testBoth,
                  icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                  label: Text(_checking ? '检测中…' : '重新检测两条通道'),
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
                    onSelectionChanged: (Set<LinkMode> selection) {
                      setState(() => _mode = selection.first);
                      ref.read(endpointResolverProvider).invalidate();
                    },
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