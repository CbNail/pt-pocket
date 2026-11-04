import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/adapters/moviepilot_adapter_registry.dart';
import '../../core/config/app_config.dart';
import '../../core/models/moviepilot.dart';
import '../../core/network/endpoint_resolver.dart' show ActiveLink;
import '../../core/network/url_utils.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import '../search/search_providers.dart';

/// 添加 / 编辑 MoviePilot 实例（需求 4、9：支持多个 MP 与搜索增强配置）。
class MpAddPage extends ConsumerStatefulWidget {
  const MpAddPage({super.key, this.instanceId});

  final String? instanceId;

  @override
  ConsumerState<MpAddPage> createState() => _MpAddPageState();
}

class _MpAddPageState extends ConsumerState<MpAddPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _lanUrl = TextEditingController();
  final TextEditingController _wanUrl = TextEditingController();
  final TextEditingController _token = TextEditingController();

  MpVersion _version = MoviePilotAdapterRegistry.defaultVersion;
  SiteProbeResult? _lanResult;
  SiteProbeResult? _wanResult;
  ActiveLink _activeLink = ActiveLink.none;
  bool _probing = false;
  bool _saving = false;
  bool _prefilled = false;

  /// 本页对应的实例 id：首次保存时生成并复用，避免「测试一次就多建一条」。
  String? _pendingId;

  bool get _isEditing => widget.instanceId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    if (!_isEditing) return;
    final MpInstance? instance = ref.read(mpByIdProvider(widget.instanceId!));
    if (instance == null) return;
    _name.text = instance.name;
    // 旧数据（单一地址）已在模型里按内网/公网归到对应通道，这里直接回填两条通道。
    _lanUrl.text = instance.lanBaseUrl;
    _wanUrl.text = instance.wanBaseUrl;
    _version = instance.version;
  }

  @override
  void dispose() {
    _name.dispose();
    _lanUrl.dispose();
    _wanUrl.dispose();
    _token.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settingsMoviePilotPath);
    }
  }

  /// 测试两条通道：内网优先判定「当前会走哪条」，两条都测以便排障。
  Future<void> _testConnection() async {
    final Uri? lan = UrlUtils.normalize(_lanUrl.text);
    final Uri? wan = UrlUtils.normalize(_wanUrl.text);
    if (_lanUrl.text.trim().isNotEmpty && lan == null) {
      _snack('内网地址格式不正确，请检查是否写成了完整地址');
      return;
    }
    if (_wanUrl.text.trim().isNotEmpty && wan == null) {
      _snack('外网地址格式不正确，请检查是否写成了完整地址');
      return;
    }
    if (lan == null && wan == null) {
      _snack('请至少填写内网或外网地址');
      return;
    }

    setState(() {
      _probing = true;
      _lanResult = null;
      _wanResult = null;
      _activeLink = ActiveLink.none;
    });

    final MpReachabilityProbe probe = ref.read(mpProbeProvider);
    final SiteProbeResult? lanResult =
        lan == null ? null : await probe(lan.toString(), timeout: AppConfig.lanProbeTimeout);
    final SiteProbeResult? wanResult =
        wan == null ? null : await probe(wan.toString(), timeout: AppConfig.wanProbeTimeout);

    if (!mounted) return;
    final bool lanOk = lanResult?.isSuccess ?? false;
    final bool wanOk = wanResult?.isSuccess ?? false;
    setState(() {
      _probing = false;
      _lanResult = lanResult;
      _wanResult = wanResult;
      _activeLink = lanOk
          ? ActiveLink.lan
          : (wanOk ? ActiveLink.wan : ActiveLink.none);
    });

    // 需求：测试后自动保存，无论测试成功或失败；并用测试结果刷新实例健康状态。
    final MpInstance saved = await _persist();
    await ref.read(mpListProvider.notifier).recordProbe(saved.id, lanOk || wanOk);
    if (!mounted) return;
    _snack('已自动保存实例 · ${lanOk ? '内网可用' : (wanOk ? '外网可用' : '两条通道均不可用')}');
  }

  /// 落盘当前表单内容（新增或更新同一条），供「测试后自动保存」与「保存实例」共用。
  Future<MpInstance> _persist() async {
    final Uri? lan = UrlUtils.normalize(_lanUrl.text);
    final Uri? wan = UrlUtils.normalize(_wanUrl.text);
    final String id = widget.instanceId ?? (_pendingId ??= const Uuid().v4());
    final String token = _token.text.trim();

    final List<MpInstance> existingList =
        ref.read(mpListProvider).valueOrNull ?? const <MpInstance>[];
    MpInstance existing = MpInstance(id: id, name: '', baseUrl: '', version: _version);
    for (final MpInstance candidate in existingList) {
      if (candidate.id == id) {
        existing = candidate;
        break;
      }
    }

    final MpInstance instance = existing.copyWith(
      id: id,
      name: _name.text.trim(),
      lanBaseUrl: lan?.toString() ?? '',
      wanBaseUrl: wan?.toString() ?? '',
      // 兼容字段：留「内网优先」的地址，供仍按单一地址展示 / 下发的地方使用。
      baseUrl: (lan ?? wan)?.toString() ?? '',
      version: _version,
      credentialConfigured: token.isNotEmpty || existing.credentialConfigured,
    );

    final MpListNotifier notifier = ref.read(mpListProvider.notifier);
    await notifier.upsert(instance);
    if (token.isNotEmpty) {
      await notifier.saveCredential(id, <String, dynamic>{
        'apiToken': token,
        'updatedAt': DateTime.now().toIso8601String(),
      });
    }
    return instance;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final MpInstance instance = await _persist();
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(_isEditing ? '已更新「${instance.name}」' : '已添加「${instance.name}」');
    _leave();
  }

  Widget _channelRow(ThemeData theme, String label, bool empty, SiteProbeResult? result) {
    final StatusBadge badge;
    if (_probing) {
      badge = const StatusBadge(label: '检测中', tone: StatusTone.neutral, compact: true);
    } else if (empty) {
      badge = const StatusBadge(label: '未配置', tone: StatusTone.neutral, compact: true);
    } else if (result == null) {
      badge = const StatusBadge(label: '未检测', tone: StatusTone.neutral, compact: true);
    } else {
      badge = StatusBadge(
        label: result.outcome.label,
        tone: result.isSuccess ? StatusTone.ok : StatusTone.danger,
        icon: result.isSuccess ? Icons.check_circle_outline : Icons.error_outline,
        compact: true,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(width: 56, child: Text(label, style: theme.textTheme.bodyMedium)),
            badge,
          ],
        ),
        if (!_probing && result != null && result.message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 56, top: AppSpacing.xxs),
            child: Text(result.message, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? instanceId = widget.instanceId;
    final AsyncValue<Map<String, dynamic>?> credentialAsync = instanceId == null
        ? const AsyncData<Map<String, dynamic>?>(null)
        : ref.watch(mpCredentialProvider(instanceId));
    final bool hasToken = credentialAsync.valueOrNull != null;
    final MpAdapterDescriptor descriptor = MoviePilotAdapterRegistry.of(_version);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑 MoviePilot' : '添加 MoviePilot'),
        leading: IconButton(icon: const Icon(Icons.close), tooltip: '取消', onPressed: _leave),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
          children: <Widget>[
            SectionCard(
              title: '实例信息',
              subtitle: '可添加多个 MP 实例；协议调用由 NAS 后端适配器完成',
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '名称'),
                    validator: (String? value) =>
                        (value == null || value.trim().isEmpty) ? '请填写名称' : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _lanUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '内网地址',
                      hintText: 'http://192.168.1.10:3000',
                    ),
                    validator: (String? value) {
                      final String lanText = value?.trim() ?? '';
                      final String wanText = _wanUrl.text.trim();
                      if (lanText.isEmpty && wanText.isEmpty) return '内网与外网至少填一个';
                      if (lanText.isNotEmpty && UrlUtils.normalize(lanText) == null) {
                        return '地址格式不正确';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _wanUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '外网地址',
                      hintText: 'https://mp.example.com:5888',
                    ),
                    validator: (String? value) {
                      final String wanText = value?.trim() ?? '';
                      final String lanText = _lanUrl.text.trim();
                      if (lanText.isEmpty && wanText.isEmpty) return '内网与外网至少填一个';
                      if (wanText.isNotEmpty && UrlUtils.normalize(wanText) == null) {
                        return '地址格式不正确';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '自动模式：内网优先（${AppConfig.lanProbeTimeout.inSeconds} 秒），'
                      '失败回退外网（${AppConfig.wanProbeTimeout.inSeconds} 秒），回到家庭网络自动切回。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<MpVersion>(
                    initialValue: _version,
                    decoration: const InputDecoration(labelText: '适配版本'),
                    items: MpVersion.values
                        .map((MpVersion v) => DropdownMenuItem<MpVersion>(
                              value: v,
                              child: Text(v.label),
                            ))
                        .toList(growable: false),
                    onChanged: (MpVersion? value) {
                      if (value == null) return;
                      setState(() => _version = value);
                    },
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(descriptor.note, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: 'API 令牌',
              subtitle: '只保存在本机安全存储，用于让服务端适配器调用该 MP',
              child: TextFormField(
                controller: _token,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'API 令牌',
                  hintText: hasToken ? '已保存，留空表示不修改' : '未保存',
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '连接测试',
              subtitle: '只探测地址可达性，不校验令牌；两条通道分别给出结果，测试后自动保存本页内容',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    onPressed: _probing ? null : _testConnection,
                    icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                    label: Text(_probing ? '测试中…' : '测试两条通道'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _channelRow(theme, '内网', _lanUrl.text.trim().isEmpty, _lanResult),
                  const SizedBox(height: AppSpacing.sm),
                  _channelRow(theme, '外网', _wanUrl.text.trim().isEmpty, _wanResult),
                  if (!_probing && _activeLink != ActiveLink.none) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text('当前会走：${_activeLink.label}通道', style: theme.textTheme.bodyMedium),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check, size: AppSizes.iconSm),
              label: Text(_saving ? '保存中…' : (_isEditing ? '保存修改' : '保存实例')),
            ),
          ],
        ),
      ),
    );
  }
}