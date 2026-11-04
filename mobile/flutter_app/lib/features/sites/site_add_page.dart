import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/adapters/site_adapter_registry.dart';
import '../../core/models/pt_site.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import 'site_providers.dart';
import 'widgets/credential_form.dart';

/// 添加站点：内置适配定义 + 凭据录入 + 连接测试（需求 1）。
class SiteAddPage extends ConsumerStatefulWidget {
  const SiteAddPage({super.key});

  @override
  ConsumerState<SiteAddPage> createState() => _SiteAddPageState();
}

class _SiteAddPageState extends ConsumerState<SiteAddPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _cookie = TextEditingController();
  final TextEditingController _secret = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  SiteFramework _framework = SiteFramework.nexusphp;
  SiteAuthType _authType = SiteAuthType.cookie;
  SiteProbeResult? _probeResult;
  bool _probing = false;
  bool _saving = false;

  /// 本页对应的站点 id：首次保存时生成并复用，避免「测试一次就多建一条」。
  String? _pendingSiteId;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _cookie.dispose();
    _secret.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onFrameworkChanged(SiteFramework? framework) {
    if (framework == null) return;
    setState(() {
      _framework = framework;
      final List<SiteAuthType> allowed = SiteAdapterRegistry.authTypesFor(framework);
      if (!allowed.contains(_authType)) {
        _authType = allowed.first;
      }
      _probeResult = null;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 测试连接：只探测地址可达性；测试后自动保存当前填写内容（无论测试成功或失败）。
  Future<void> _testConnection() async {
    final String url = _url.text.trim();
    if (url.isEmpty) {
      _snack('请先填写站点地址');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      _snack('站点名称与地址填好后测试，测试成功与否都会自动保存');
      return;
    }
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final SiteProbeResult result = await ref.read(siteProbeProvider)(url);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = result;
    });
    await _persist();
    if (!mounted) return;
    _snack('已自动保存站点 · 连接测试：${result.outcome.label}');
  }

  /// 落盘当前表单内容（新增或更新同一条），供「测试后自动保存」与「保存站点」共用。
  Future<PtSite> _persist() async {
    final String id = _pendingSiteId ??= const Uuid().v4();
    final Map<String, dynamic>? credential = buildCredentialMap(
      _authType,
      cookie: _cookie.text,
      secret: _secret.text,
      username: _username.text,
      password: _password.text,
    );
    final PtSite site = PtSite(
      id: id,
      name: _name.text.trim(),
      baseUrl: SiteReachabilityProbe.parseSiteUri(_url.text)?.toString() ?? _url.text.trim(),
      framework: _framework,
      authType: _authType,
      credentialConfigured: credential != null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final SiteListNotifier notifier = ref.read(siteListProvider.notifier);
    await notifier.upsert(site);
    if (credential != null) {
      await notifier.saveCredential(id, credential);
    }
    return site;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final PtSite site = await _persist();
    if (!mounted) return;
    setState(() => _saving = false);
    _snack('已添加站点「${site.name}」');
    _leave();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.sites);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SiteAdapterDescriptor descriptor = SiteAdapterRegistry.of(_framework);
    final List<SiteAuthType> authTypes = SiteAdapterRegistry.authTypesFor(_framework);

    return Scaffold(
      appBar: AppBar(
        title: const Text('添加站点'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '取消',
          onPressed: _leave,
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
          children: <Widget>[
            SectionCard(
              title: '站点信息',
              subtitle: '适配定义决定服务端用哪个适配器解析该站点',
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '站点名称'),
                    validator: (String? value) =>
                        (value == null || value.trim().isEmpty) ? '请填写站点名称' : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextFormField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '站点地址',
                      hintText: 'https://example.com',
                    ),
                    validator: (String? value) {
                      final String text = value?.trim() ?? '';
                      if (text.isEmpty) return '请填写站点地址';
                      if (SiteReachabilityProbe.parseSiteUri(text) == null) return '站点地址格式不正确';
                      return null;
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<SiteFramework>(
                    initialValue: _framework,
                    decoration: const InputDecoration(labelText: '适配定义'),
                    items: SiteFramework.values
                        .map((SiteFramework f) => DropdownMenuItem<SiteFramework>(
                              value: f,
                              child: Text(f.label),
                            ))
                        .toList(growable: false),
                    onChanged: _onFrameworkChanged,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(descriptor.note, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '认证方式与凭据',
              subtitle: '凭据只保存在本机安全存储，不写入普通配置',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  DropdownButtonFormField<SiteAuthType>(
                    initialValue: _authType,
                    decoration: const InputDecoration(labelText: '认证方式'),
                    items: authTypes
                        .map((SiteAuthType t) => DropdownMenuItem<SiteAuthType>(
                              value: t,
                              child: Text(t.label),
                            ))
                        .toList(growable: false),
                    onChanged: (SiteAuthType? value) {
                      if (value == null) return;
                      setState(() => _authType = value);
                    },
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(_authType.description, style: theme.textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.md),
                  CredentialFields(
                    authType: _authType,
                    cookieController: _cookie,
                    secretController: _secret,
                    usernameController: _username,
                    passwordController: _password,
                  ),
                  if (_authType == SiteAuthType.account) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '账号密码仅用于内置 WebView 手动登录，不会提交给服务端；'
                      '登录后可在站点详情里抓取 Cookie。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '连接测试',
              subtitle: '只探测站点地址可达性，不校验凭据有效性；测试后自动保存本页内容',
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
              label: Text(_saving ? '保存中…' : '保存站点'),
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: () => context.go(AppRoutes.sitePtdImportPath),
              icon: const Icon(Icons.file_upload_outlined, size: AppSizes.iconSm),
              label: const Text('从 PTD 备份批量导入'),
            ),
          ],
        ),
      ),
    );
  }
}