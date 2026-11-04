import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/downloader.dart';
import '../../core/network/address_probe_controller.dart';
import '../../core/network/url_utils.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/storage/probe_result_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/address_field.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import 'downloader_providers.dart';

/// 添加 / 编辑下载器（需求 3）。
///
/// 账号密码只保存在本机安全存储；各引擎协议调用由 NAS 后端适配器完成。
///
/// 本轮改造要点（地址录入与实时连通）：
/// - 地址按「协议点选 + 主机 + 端口（可改）+ 可选子路径」分开录入，粘贴整条 URL 自动拆分；
/// - 端口按引擎给出默认值（qBittorrent 8080 / Transmission 9091 / Aria2 6800）；
/// - 填完即探测，地址后直接给出连通标记；测试后自动保存本页内容；
/// - 探测结论落盘（key `downloader.<id>`），重新进入页面按已存地址实测，而不是一律「未检测」。
class DownloaderAddPage extends ConsumerStatefulWidget {
  const DownloaderAddPage({super.key, this.downloaderId});

  /// 传入时为编辑已有下载器。
  final String? downloaderId;

  @override
  ConsumerState<DownloaderAddPage> createState() => _DownloaderAddPageState();
}

class _DownloaderAddPageState extends ConsumerState<DownloaderAddPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _path = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _savePath = TextEditingController();

  DownloaderKind _kind = DownloaderKind.qbittorrent;
  String _scheme = 'http';
  bool _saving = false;
  bool _prefilled = false;

  /// 本页对应的下载器 id：首次落盘时生成并复用，避免「测试一次就多建一条」。
  String? _pendingId;

  late final AddressProbeController _probes;
  late final String _probeKey;

  bool get _isEditing => widget.downloaderId != null;

  @override
  void initState() {
    super.initState();
    // 新建时先定下 id，探测结果才有稳定的落盘 key（此时还不会创建记录）。
    if (!_isEditing) _pendingId = const Uuid().v4();
    _probeKey = 'downloader.${widget.downloaderId ?? _pendingId}';
    _probes = AddressProbeController(
      store: ref.read(probeResultStoreProvider),
      probe: _probe,
      // 下载器是内网自建服务，超时按内网档处理。
      timeout: Duration(seconds: 5),
    )..addListener(_onProbeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 编辑模式下仅预填一次，避免用户输入被后续依赖变化覆盖。
    if (_prefilled) return;
    _prefilled = true;
    if (_isEditing) {
      final DownloaderConfig? config = ref.read(downloaderByIdProvider(widget.downloaderId!));
      if (config != null) {
        _name.text = config.name;
        _kind = config.kind;
        _fillAddress(config.baseUrl);
        _username.text = config.username;
        _savePath.text = config.defaultSavePath;
      }
    }
    if (_port.text.trim().isEmpty) _port.text = '${_defaultPortForKind(_kind)}';
    // 进页面就按已存地址实测一次：状态实时，而不是固定「未检测」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _configured) _probes.probeNow(_probeKey, _uri);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _username.dispose();
    _password.dispose();
    _savePath.dispose();
    _probes.dispose();
    super.dispose();
  }

  // ---------- 地址 ----------

  static int _defaultPortForKind(DownloaderKind kind) => switch (kind) {
        DownloaderKind.qbittorrent => 8080,
        DownloaderKind.transmission => 9091,
        DownloaderKind.aria2 => 6800,
      };

  bool get _configured => _host.text.trim().isNotEmpty;

  Uri? get _uri => UrlUtils.compose(
        scheme: _scheme,
        host: _host.text,
        port: _port.text,
        path: _path.text.trim(),
      );

  void _fillAddress(String baseUrl) {
    final AddressParts parts = UrlUtils.split(baseUrl);
    if (parts.isEmpty) {
      _scheme = 'http';
      _host.text = baseUrl;
      return;
    }
    _scheme = parts.scheme;
    _host.text = parts.host;
    _port.text = parts.portText;
    _path.text = parts.path;
  }

  /// 切换协议时的端口兜底：空值或另一种协议的默认端口跟着换。
  void _onSchemeChanged(String value) {
    setState(() {
      _port.text = UrlUtils.adjustPortForScheme(scheme: value, currentPort: _port.text);
      _scheme = value;
    });
    _scheduleProbe();
  }

  /// 切换引擎时的端口兜底：空值或其它引擎的默认端口跟着换成新引擎默认端口。
  void _onKindChanged(DownloaderKind value) {
    setState(() {
      final String current = _port.text.trim();
      final int next = _defaultPortForKind(value);
      final bool isOtherDefault = current.isNotEmpty &&
          DownloaderKind.values
              .where((DownloaderKind k) => k != value)
              .any((DownloaderKind k) => current == _defaultPortForKind(k).toString());
      if (current.isEmpty || isOtherDefault) _port.text = '$next';
      _kind = value;
    });
    _scheduleProbe();
  }

  void _scheduleProbe() => _probes.schedule(_probeKey, _configured ? _uri : null);

  Future<ProbeSnapshot> _probe(Uri target, Duration timeout) async =>
      snapshotFromSiteProbe(
        await ref.read(downloaderProbeProvider)(target.toString(), timeout: timeout),
        target,
      );

  void _onProbeChanged() {
    if (mounted) setState(() {});
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.downloaders);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 测试连接：探测地址可达性并落盘结论；测试后自动保存当前填写内容（无论成功或失败）。
  Future<void> _testConnection() async {
    if (!_configured) {
      _snack('请先填写下载器地址');
      return;
    }
    if (_uri == null) {
      _snack('端口不正确：请填 1–65535 之间的数字');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      _snack('名称与地址填好后测试，测试成功与否都会自动保存');
      return;
    }
    await _probes.probeNow(_probeKey, _uri);
    final ProbeSnapshot? snapshot = _probes.snapshot(_probeKey);

    final DownloaderConfig saved = await _persist();
    await ref
        .read(downloaderListProvider.notifier)
        .recordProbe(saved.id, snapshot?.reachable ?? false);
    if (!mounted) return;
    _snack('已自动保存下载器 · 连接测试：${snapshot?.reachable == true ? '地址可达' : '不可达'}');
  }

  /// 落盘当前表单内容（新增或更新同一条），供「测试后自动保存」与「保存下载器」共用。
  Future<DownloaderConfig> _persist() async {
    final String id = widget.downloaderId ?? (_pendingId ??= const Uuid().v4());
    final String username = _username.text.trim();
    final String password = _password.text;

    final Map<String, dynamic>? credential = (username.isEmpty && password.isEmpty)
        ? null
        : <String, dynamic>{
            'username': username,
            'password': password,
            'updatedAt': DateTime.now().toIso8601String(),
          };

    final List<DownloaderConfig> existingList =
        ref.read(downloaderListProvider).valueOrNull ?? const <DownloaderConfig>[];
    DownloaderConfig existing = DownloaderConfig(id: id, name: '', kind: _kind, baseUrl: '');
    for (final DownloaderConfig candidate in existingList) {
      if (candidate.id == id) {
        existing = candidate;
        break;
      }
    }

    final DownloaderConfig config = existing.copyWith(
      id: id,
      name: _name.text.trim(),
      kind: _kind,
      baseUrl: _uri?.toString() ?? _host.text.trim(),
      username: username,
      defaultSavePath: _savePath.text.trim(),
      credentialConfigured: credential != null || existing.credentialConfigured,
    );

    final DownloaderListNotifier notifier = ref.read(downloaderListProvider.notifier);
    await notifier.upsert(config);
    if (credential != null) {
      await notifier.saveCredential(id, credential);
    }
    return config;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_configured) {
      _snack('请填写下载器地址（主机与端口）');
      return;
    }
    if (_uri == null) {
      _snack('地址不正确：请检查端口是否为 1–65535');
      return;
    }
    setState(() => _saving = true);
    final DownloaderConfig config = await _persist();
    if (!mounted) return;
    setState(() => _saving = false);
    _snack(_isEditing ? '已更新「${config.name}」' : '已添加下载器「${config.name}」');
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? downloaderId = widget.downloaderId;
    final AsyncValue<Map<String, dynamic>?> credentialAsync = downloaderId == null
        ? const AsyncData<Map<String, dynamic>?>(null)
        : ref.watch(downloaderCredentialProvider(downloaderId));
    final bool hasPassword = credentialAsync.valueOrNull != null;
    final ProbeSnapshot? snapshot = _probes.snapshot(_probeKey);
    final bool probing = _probes.isProbing(_probeKey);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑下载器' : '添加下载器'),
        leading: IconButton(icon: const Icon(Icons.close), tooltip: '取消', onPressed: _leave),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
          children: <Widget>[
            SectionCard(
              title: '下载器信息',
              subtitle: '协议点选、主机与端口分开填；填完即自动检测，测试后自动保存',
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '名称'),
                    validator: (String? value) =>
                        (value == null || value.trim().isEmpty) ? '请填写名称' : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<DownloaderKind>(
                    initialValue: _kind,
                    decoration: const InputDecoration(labelText: '类型'),
                    items: DownloaderKind.values
                        .map((DownloaderKind k) => DropdownMenuItem<DownloaderKind>(
                              value: k,
                              child: Text(k.label),
                            ))
                        .toList(growable: false),
                    onChanged: (DownloaderKind? value) {
                      if (value == null) return;
                      _onKindChanged(value);
                    },
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_kind.description, style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AddressInput(
                    label: '地址',
                    keyPrefix: 'downloader',
                    scheme: _scheme,
                    hostController: _host,
                    portController: _port,
                    pathController: _path,
                    onSchemeChanged: _onSchemeChanged,
                    snapshot: snapshot,
                    probing: probing,
                    hostHint: '192.168.1.10',
                    onEdited: _scheduleProbe,
                    onSubmitted: () => _probes.probeNow(_probeKey, _uri),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _savePath,
                    decoration: const InputDecoration(
                      labelText: '默认保存目录（可选）',
                      hintText: '/downloads/PT',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '账号密码',
              subtitle: '只保存在本机安全存储，用于服务端适配器登录下载器',
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '密码',
                      hintText: hasPassword ? '已保存，留空表示不修改' : '未保存',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '连接测试',
              subtitle: '只探测地址可达性，不校验账号有效性与引擎版本；测试后自动保存本页内容',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: probing ? null : _testConnection,
                        icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                        label: Text(probing ? '测试中…' : '测试连接'),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      if (!probing && snapshot != null)
                        StatusBadge(
                          label: describeProbe(snapshot),
                          tone: snapshot.usable
                              ? StatusTone.ok
                              : (snapshot.reachable ? StatusTone.warning : StatusTone.danger),
                          icon: snapshot.usable
                              ? Icons.check_circle_outline
                              : (snapshot.reachable
                                  ? Icons.error_outline
                                  : Icons.cancel_outlined),
                        ),
                    ],
                  ),
                  if (!probing && snapshot != null && snapshot.message.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text(snapshot.message, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check, size: AppSizes.iconSm),
              label: Text(_saving ? '保存中…' : (_isEditing ? '保存修改' : '保存下载器')),
            ),
          ],
        ),
      ),
    );
  }
}