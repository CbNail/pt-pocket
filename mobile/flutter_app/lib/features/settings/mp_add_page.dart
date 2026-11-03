import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/adapters/moviepilot_adapter_registry.dart';
import '../../core/models/moviepilot.dart';
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
  final TextEditingController _url = TextEditingController();
  final TextEditingController _token = TextEditingController();

  MpVersion _version = MoviePilotAdapterRegistry.defaultVersion;
  SiteProbeResult? _probeResult;
  bool _probing = false;
  bool _saving = false;
  bool _prefilled = false;

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
    _url.text = instance.baseUrl;
    _version = instance.version;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settingsMoviePilotPath);
    }
  }

  Future<void> _testConnection() async {
    final String url = _url.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先填写 MP 地址')));
      return;
    }
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final SiteProbeResult result = await ref.read(mpProbeProvider)(url);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = result;
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final Uri? uri = SiteReachabilityProbe.parseSiteUri(_url.text);
    final String id = widget.instanceId ?? const Uuid().v4();
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
      baseUrl: uri?.toString() ?? _url.text.trim(),
      version: _version,
      credentialConfigured: token.isNotEmpty || existing.credentialConfigured,
    );

    setState(() => _saving = true);
    final MpListNotifier notifier = ref.read(mpListProvider.notifier);
    await notifier.upsert(instance);
    if (token.isNotEmpty) {
      await notifier.saveCredential(id, <String, dynamic>{
        'apiToken': token,
        'updatedAt': DateTime.now().toIso8601String(),
      });
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_isEditing ? '已更新「${instance.name}」' : '已添加「${instance.name}」')),
    );
    _leave();
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
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '地址',
                      hintText: 'http://192.168.1.10:3000',
                    ),
                    validator: (String? value) {
                      final String text = value?.trim() ?? '';
                      if (text.isEmpty) return '请填写 MP 地址';
                      if (SiteReachabilityProbe.parseSiteUri(text) == null) return '地址格式不正确';
                      return null;
                    },
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
              subtitle: '只探测地址可达性，不校验令牌',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: _probing ? null : _testConnection,
                        icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                        label: Text(_probing ? '测试中…' : '测试连接'),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      if (_probeResult != null)
                        StatusBadge(
                          label: _probeResult!.outcome.label,
                          tone: _probeResult!.isSuccess ? StatusTone.ok : StatusTone.danger,
                          icon: _probeResult!.isSuccess
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                        ),
                    ],
                  ),
                  if (_probeResult != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text(_probeResult!.message, style: theme.textTheme.bodySmall),
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