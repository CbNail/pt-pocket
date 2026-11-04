import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/adapters/moviepilot_adapter_registry.dart';
import '../../core/config/app_config.dart';
import '../../core/models/moviepilot.dart';
import '../../core/network/address_probe_controller.dart';
import '../../core/network/url_utils.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/storage/probe_result_store.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/address_field.dart';
import '../../shared/widgets/channel_switch.dart';
import '../../shared/widgets/section_card.dart';
import '../search/search_providers.dart';

/// 添加 / 编辑 MoviePilot 实例（需求 4、9：支持多个 MP 与搜索增强配置）。
///
/// 本轮改造要点（地址录入与实时连通）：
/// - 内网 / 外网地址按「协议点选 + 主机 + 端口（可改）+ 可选子路径」分开录入；
/// - 两条通道**分别探测**，各自带连通标记，整体情况汇总在「服务地址」框底部；
/// - 探测结论落盘（`mp.<id>.lan` / `mp.<id>.wan`），重进页面按已存地址实测，
///   不会一直是「未检测」；测试后自动保存本页内容。
class MpAddPage extends ConsumerStatefulWidget {
  const MpAddPage({super.key, this.instanceId});

  final String? instanceId;

  @override
  ConsumerState<MpAddPage> createState() => _MpAddPageState();
}

class _MpAddPageState extends ConsumerState<MpAddPage> {
  static const int _defaultLanPort = 3000;
  static const int _defaultWanPort = 443;

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _lanHost = TextEditingController();
  final TextEditingController _lanPort = TextEditingController();
  final TextEditingController _lanPath = TextEditingController();
  final TextEditingController _wanHost = TextEditingController();
  final TextEditingController _wanPort = TextEditingController();
  final TextEditingController _wanPath = TextEditingController();
  final TextEditingController _token = TextEditingController();

  MpVersion _version = MoviePilotAdapterRegistry.defaultVersion;

  /// 当前展示的通道：0 内网 / 1 外网（一次只显示一条，避免两栏并排）。
  int _activeChannel = 0;
  String _lanScheme = 'http';
  String _wanScheme = 'https';
  bool _saving = false;
  bool _prefilled = false;

  /// 本页对应的实例 id：首次落盘时生成并复用，避免「测试一次就多建一条」。
  String? _pendingId;

  late final AddressProbeController _lanProbes;
  late final AddressProbeController _wanProbes;
  late final String _lanKey;
  late final String _wanKey;

  bool get _isEditing => widget.instanceId != null;

  @override
  void initState() {
    super.initState();
    if (!_isEditing) _pendingId = const Uuid().v4();
    final String id = widget.instanceId ?? _pendingId!;
    _lanKey = 'mp.$id.lan';
    _wanKey = 'mp.$id.wan';

    final ProbeResultStore store = ref.read(probeResultStoreProvider);
    _lanProbes = AddressProbeController(
      store: store,
      probe: _probe,
      timeout: AppConfig.lanProbeTimeout,
    )..addListener(_onProbeChanged);
    _wanProbes = AddressProbeController(
      store: store,
      probe: _probe,
      timeout: AppConfig.wanProbeTimeout,
    )..addListener(_onProbeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    if (_isEditing) {
      final MpInstance? instance = ref.read(mpByIdProvider(widget.instanceId!));
      if (instance != null) {
        _name.text = instance.name;
        // 旧数据（单一地址）已在模型里按内网/公网归到对应通道，这里直接回填两条通道。
        _fillChannel(instance.lanBaseUrl, isLan: true);
        _fillChannel(instance.wanBaseUrl, isLan: false);
        _version = instance.version;
      }
    }
    if (_lanPort.text.trim().isEmpty) _lanPort.text = '$_defaultLanPort';
    if (_wanPort.text.trim().isEmpty) _wanPort.text = '$_defaultWanPort';

    // 进页面就按已存地址实测两条通道：状态实时，而不是固定「未检测」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reprobeAll();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _lanHost.dispose();
    _lanPort.dispose();
    _lanPath.dispose();
    _wanHost.dispose();
    _wanPort.dispose();
    _wanPath.dispose();
    _token.dispose();
    _lanProbes.dispose();
    _wanProbes.dispose();
    super.dispose();
  }

  // ---------- 地址 ----------

  bool get _lanConfigured => _lanHost.text.trim().isNotEmpty;
  bool get _wanConfigured => _wanHost.text.trim().isNotEmpty;

  Uri? get _lanUri => UrlUtils.compose(
        scheme: _lanScheme,
        host: _lanHost.text,
        port: _lanPort.text,
        path: _lanPath.text.trim(),
      );

  Uri? get _wanUri => UrlUtils.compose(
        scheme: _wanScheme,
        host: _wanHost.text,
        port: _wanPort.text,
        path: _wanPath.text.trim(),
      );

  void _fillChannel(String baseUrl, {required bool isLan}) {
    final AddressParts parts = UrlUtils.split(baseUrl);
    if (isLan) {
      if (parts.isEmpty) {
        _lanHost.text = baseUrl;
        return;
      }
      _lanScheme = parts.scheme;
      _lanHost.text = parts.host;
      _lanPort.text = parts.portText;
      _lanPath.text = parts.path;
    } else {
      if (parts.isEmpty) {
        _wanHost.text = baseUrl;
        return;
      }
      _wanScheme = parts.scheme;
      _wanHost.text = parts.host;
      _wanPort.text = parts.portText;
      _wanPath.text = parts.path;
    }
  }

  void _onSchemeChanged({required bool isLan, required String value}) {
    setState(() {
      if (isLan) {
        _lanPort.text = UrlUtils.adjustPortForScheme(scheme: value, currentPort: _lanPort.text);
        _lanScheme = value;
      } else {
        _wanPort.text = UrlUtils.adjustPortForScheme(scheme: value, currentPort: _wanPort.text);
        _wanScheme = value;
      }
    });
    _scheduleProbe(isLan: isLan);
  }

  Future<ProbeSnapshot> _probe(Uri target, Duration timeout) async =>
      snapshotFromSiteProbe(
        // MP 没有 /api/v1/health，可用性以「能否拿到站点响应」为准（401/403 也算连通）。
        await ref.read(mpProbeProvider)(target.toString(), timeout: timeout),
        target,
      );

  void _onProbeChanged() {
    if (mounted) setState(() {});
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

  void _scheduleProbe({required bool isLan}) {
    if (isLan) {
      _lanProbes.schedule(_lanKey, _lanConfigured ? _lanUri : null);
    } else {
      _wanProbes.schedule(_wanKey, _wanConfigured ? _wanUri : null);
    }
  }

  Future<void> _reprobeAll() async {
    await Future.wait<void>(<Future<void>>[
      if (_lanConfigured) _lanProbes.probeNow(_lanKey, _lanUri),
      if (_wanConfigured) _wanProbes.probeNow(_wanKey, _wanUri),
    ]);
  }

  /// 当前实际优先使用的通道（供底部整体情况展示）。
  String _activeLabel() {
    if (_lanProbes.snapshot(_lanKey)?.usable ?? false) return '内网';
    if (_wanProbes.snapshot(_wanKey)?.usable ?? false) return '外网';
    return '';
  }

  /// 测试两条通道：内网优先判定「当前会走哪条」，两条都测以便排障。
  Future<void> _testConnection() async {
    if (_lanConfigured && _lanUri == null) {
      _snack('内网主机或端口不正确，请检查');
      return;
    }
    if (_wanConfigured && _wanUri == null) {
      _snack('外网主机或端口不正确，请检查');
      return;
    }
    if (!_lanConfigured && !_wanConfigured) {
      _snack('请至少填写内网或外网地址');
      return;
    }

    setState(() {});
    await _reprobeAll();
    final bool lanOk = _lanProbes.snapshot(_lanKey)?.usable ?? false;
    final bool wanOk = _wanProbes.snapshot(_wanKey)?.usable ?? false;

    // 需求：测试后自动保存，无论测试成功或失败；并用测试结果刷新实例健康状态。
    final MpInstance saved = await _persist();
    await ref.read(mpListProvider.notifier).recordProbe(saved.id, lanOk || wanOk);
    if (!mounted) return;
    _snack('已自动保存实例 · ${lanOk ? '内网可用' : (wanOk ? '外网可用' : '两条通道均不可用')}');
  }

  /// 落盘当前表单内容（新增或更新同一条），供「测试后自动保存」与「保存实例」共用。
  Future<MpInstance> _persist() async {
    final Uri? lan = _lanUri;
    final Uri? wan = _wanUri;
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
      lanBaseUrl: _lanConfigured ? (lan?.toString() ?? '') : '',
      wanBaseUrl: _wanConfigured ? (wan?.toString() ?? '') : '',
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? instanceId = widget.instanceId;
    final AsyncValue<Map<String, dynamic>?> credentialAsync = instanceId == null
        ? const AsyncData<Map<String, dynamic>?>(null)
        : ref.watch(mpCredentialProvider(instanceId));
    final bool hasToken = credentialAsync.valueOrNull != null;
    final MpAdapterDescriptor descriptor = MoviePilotAdapterRegistry.of(_version);
    final ProbeSnapshot? lanSnapshot = _lanProbes.snapshot(_lanKey);
    final ProbeSnapshot? wanSnapshot = _wanProbes.snapshot(_wanKey);
    final bool probing = _lanProbes.isProbing(_lanKey) || _wanProbes.isProbing(_wanKey);

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
              title: '服务地址',
              subtitle: '协议点选、主机与端口分开填；左侧切换内网 / 外网，两条通道分别检测，整体情况在最下方',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '名称'),
                    validator: (String? value) =>
                        (value == null || value.trim().isEmpty) ? '请填写名称' : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ChannelSwitch(
                    index: _activeChannel,
                    onIndexChanged: (int value) => setState(() => _activeChannel = value),
                    panes: <ChannelPane>[
                      ChannelPane(
                        label: '内网',
                        configured: _lanConfigured,
                        snapshot: lanSnapshot,
                        probing: _lanProbes.isProbing(_lanKey),
                        child: AddressInput(
                          label: '内网地址',
                          keyPrefix: 'mp.lan',
                          scheme: _lanScheme,
                          hostController: _lanHost,
                          portController: _lanPort,
                          pathController: _lanPath,
                          onSchemeChanged: (String value) =>
                              _onSchemeChanged(isLan: true, value: value),
                          snapshot: lanSnapshot,
                          probing: _lanProbes.isProbing(_lanKey),
                          hostHint: '192.168.1.10',
                          onEdited: () => _scheduleProbe(isLan: true),
                          onSubmitted: () => _lanProbes.probeNow(_lanKey, _lanUri),
                        ),
                      ),
                      ChannelPane(
                        label: '外网',
                        configured: _wanConfigured,
                        snapshot: wanSnapshot,
                        probing: _wanProbes.isProbing(_wanKey),
                        child: AddressInput(
                          label: '外网地址',
                          keyPrefix: 'mp.wan',
                          scheme: _wanScheme,
                          hostController: _wanHost,
                          portController: _wanPort,
                          pathController: _wanPath,
                          onSchemeChanged: (String value) =>
                              _onSchemeChanged(isLan: false, value: value),
                          snapshot: wanSnapshot,
                          probing: _wanProbes.isProbing(_wanKey),
                          hostHint: 'mp.example.com',
                          onEdited: () => _scheduleProbe(isLan: false),
                          onSubmitted: () => _wanProbes.probeNow(_wanKey, _wanUri),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '自动模式：内网优先（${AppConfig.lanProbeTimeout.inSeconds} 秒），'
                    '失败回退外网（${AppConfig.wanProbeTimeout.inSeconds} 秒），回到家庭网络自动切回。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const Divider(height: AppSpacing.xl),
                  AddressPairSummary(
                    items: <AddressSummaryItem>[
                      AddressSummaryItem(
                        name: '内网',
                        configured: _lanConfigured,
                        snapshot: lanSnapshot,
                        probing: _lanProbes.isProbing(_lanKey),
                      ),
                      AddressSummaryItem(
                        name: '外网',
                        configured: _wanConfigured,
                        snapshot: wanSnapshot,
                        probing: _wanProbes.isProbing(_wanKey),
                      ),
                    ],
                    activeLabel: _activeLabel(),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.tonalIcon(
                    onPressed: probing ? null : _testConnection,
                    icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                    label: Text(probing ? '测试中…' : '测试两条通道'),
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
                  Text(descriptor.note, style: theme.textTheme.bodySmall),
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