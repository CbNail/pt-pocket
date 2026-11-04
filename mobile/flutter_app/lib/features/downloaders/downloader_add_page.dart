import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/downloader.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import 'downloader_providers.dart';

/// 添加 / 编辑下载器（需求 3）。
///
/// 账号密码只保存在本机安全存储；各引擎协议调用由 NAS 后端适配器完成。
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
  final TextEditingController _url = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _savePath = TextEditingController();

  DownloaderKind _kind = DownloaderKind.qbittorrent;
  SiteProbeResult? _probeResult;
  bool _probing = false;
  bool _saving = false;
  bool _prefilled = false;

  /// 本页对应的下载器 id：首次保存时生成并复用，避免「测试一次就多建一条」。
  String? _pendingId;

  bool get _isEditing => widget.downloaderId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 编辑模式下仅预填一次，避免用户输入被后续依赖变化覆盖。
    if (_prefilled) return;
    _prefilled = true;
    if (!_isEditing) return;

    final DownloaderConfig? config = ref.read(downloaderByIdProvider(widget.downloaderId!));
    if (config == null) return;
    _name.text = config.name;
    _url.text = config.baseUrl;
    _username.text = config.username;
    _savePath.text = config.defaultSavePath;
    _kind = config.kind;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _savePath.dispose();
    super.dispose();
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

  /// 测试连接：只探测地址可达性；测试后自动保存当前填写内容（无论测试成功或失败）。
  Future<void> _testConnection() async {
    final String url = _url.text.trim();
    if (url.isEmpty) {
      _snack('请先填写下载器地址');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      _snack('名称与地址填好后测试，测试成功与否都会自动保存');
      return;
    }
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final SiteProbeResult result = await ref.read(downloaderProbeProvider)(url);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = result;
    });

    final DownloaderConfig saved = await _persist();
    await ref.read(downloaderListProvider.notifier).recordProbe(saved.id, result.isSuccess);
    if (!mounted) return;
    _snack('已自动保存下载器 · 连接测试：${result.outcome.label}');
  }

  /// 落盘当前表单内容（新增或更新同一条），供「测试后自动保存」与「保存下载器」共用。
  Future<DownloaderConfig> _persist() async {
    final Uri? uri = SiteReachabilityProbe.parseSiteUri(_url.text);
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
      baseUrl: uri?.toString() ?? _url.text.trim(),
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
              subtitle: '引擎差异由服务端适配器消解，App 只需填地址与账号',
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
                      setState(() {
                        _kind = value;
                        _probeResult = null;
                      });
                    },
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_kind.description, style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '地址',
                      hintText: 'http://192.168.1.10:8080',
                    ),
                    validator: (String? value) {
                      final String text = value?.trim() ?? '';
                      if (text.isEmpty) return '请填写下载器地址';
                      if (SiteReachabilityProbe.parseSiteUri(text) == null) return '地址格式不正确';
                      return null;
                    },
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
                        onPressed: _probing ? null : _testConnection,
                        icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                        label: Text(_probing ? '测试中…' : '测试连接'),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      if (_probeResult != null)
                        StatusBadge(
                          label: _probeResult!.outcome.label,
                          tone: _probeResult!.isSuccess ? StatusTone.ok : StatusTone.danger,
                          icon: _probeResult!.isSuccess ? Icons.check_circle_outline : Icons.error_outline,
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
              label: Text(_saving ? '保存中…' : (_isEditing ? '保存修改' : '保存下载器')),
            ),
          ],
        ),
      ),
    );
  }
}