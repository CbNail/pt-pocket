import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/pt_site.dart';
import '../../core/network/address_probe_controller.dart';
import '../../core/network/url_utils.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/cookiecloud_service.dart';
import '../../core/storage/app_keys.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/storage/probe_result_store.dart';
import '../../core/storage/secure_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/address_field.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import 'site_providers.dart';

/// CookieCloud 一键导入（需求 1）。
///
/// 口令只在本机参与解密，不发送给 CookieCloud 服务端；
/// 解析出的 Cookie 按域名匹配已添加站点后写入本机安全存储。
class CookieCloudImportPage extends ConsumerStatefulWidget {
  const CookieCloudImportPage({super.key, this.siteId});

  /// 从站点详情进入时的目标站点。
  final String? siteId;

  @override
  ConsumerState<CookieCloudImportPage> createState() => _CookieCloudImportPageState();
}

class _CookieCloudImportPageState extends ConsumerState<CookieCloudImportPage> {
  static const String _probeKey = 'cookiecloud';

  final TextEditingController _host = TextEditingController();
  final TextEditingController _port = TextEditingController();
  final TextEditingController _path = TextEditingController();
  final TextEditingController _uuid = TextEditingController();
  final TextEditingController _password = TextEditingController();

  String _scheme = 'http';
  bool _loading = false;
  String? _error;
  CookieCloudBundle? _bundle;

  /// 实际生效的请求地址（排障用：能看出协议猜错还是反代路径不对）。
  String? _usedUri;

  late final AddressProbeController _probes;

  @override
  void initState() {
    super.initState();
    // 上次填过的地址 / UUID / 密码自动回填，不用每次重敲。
    final PrefsStore prefs = ref.read(prefsStoreProvider);
    _fillAddress(prefs.getString(PrefKeys.cookieCloudHost) ?? '');
    if (_port.text.trim().isEmpty) _port.text = '${UrlUtils.defaultPort(_scheme)}';
    _uuid.text = prefs.getString(PrefKeys.cookieCloudUuid) ?? '';

    _probes = AddressProbeController(
      store: ref.read(probeResultStoreProvider),
      probe: _probe,
      timeout: const Duration(seconds: 5),
    )..addListener(_onProbeChanged);

    ref.read(secureStoreProvider).read(SecureKeys.cookieCloudKey).then((String? value) {
      if (!mounted || value == null || value.isEmpty) return;
      setState(() => _password.text = value);
    });

    // 进页面就按已存地址实测一次：状态实时，而不是固定「未检测」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _configured) _probes.probeNow(_probeKey, _uri);
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _path.dispose();
    _uuid.dispose();
    _password.dispose();
    _probes.dispose();
    super.dispose();
  }

  // ---------- 地址 ----------

  bool get _configured => _host.text.trim().isNotEmpty;

  Uri? get _uri => UrlUtils.compose(
        scheme: _scheme,
        host: _host.text,
        port: _port.text,
        path: _path.text.trim(),
      );

  void _fillAddress(String raw) {
    final AddressParts parts = UrlUtils.split(raw);
    if (parts.isEmpty) {
      _host.text = raw.trim();
      return;
    }
    _scheme = parts.scheme;
    _host.text = parts.host;
    _port.text = parts.portText;
    _path.text = parts.path;
  }

  void _onSchemeChanged(String value) {
    setState(() {
      _port.text = UrlUtils.adjustPortForScheme(scheme: value, currentPort: _port.text);
      _scheme = value;
    });
    _scheduleProbe();
  }

  void _scheduleProbe() => _probes.schedule(_probeKey, _configured ? _uri : null);

  Future<ProbeSnapshot> _probe(Uri target, Duration timeout) async =>
      snapshotFromSiteProbe(
        await ref.read(siteReachabilityProbeProvider)(target.toString(), timeout: timeout),
        target,
      );

  void _onProbeChanged() {
    if (mounted) setState(() {});
  }

  /// 落盘本次填写的参数：无论拉取成功还是失败都保存（需求：测试后自动保存）。
  Future<void> _persistInput() async {
    final PrefsStore prefs = ref.read(prefsStoreProvider);
    await prefs.setString(PrefKeys.cookieCloudHost, _uri?.toString() ?? _host.text.trim());
    await prefs.setString(PrefKeys.cookieCloudUuid, _uuid.text.trim());
    final SecureStore secure = ref.read(secureStoreProvider);
    if (_password.text.isEmpty) {
      await secure.delete(SecureKeys.cookieCloudKey);
    } else {
      await secure.write(SecureKeys.cookieCloudKey, _password.text);
    }
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.sites);
    }
  }

  Future<void> _fetch() async {
    final String host = _uri?.toString() ?? _host.text.trim();
    final String uuid = _uuid.text.trim();
    final String password = _password.text;
    if (_host.text.trim().isEmpty || uuid.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写服务器地址、UUID 与密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _bundle = null;
      _usedUri = null;
    });

    CookieCloudImport? imported;
    String? failure;
    try {
      imported = await ref
          .read(cookieCloudServiceProvider)
          .fetchAndImport(host: host, uuid: uuid, password: password);
    } on CookieCloudException catch (error) {
      failure = error.message;
    }

    // 不管成功还是失败，填过的地址 / UUID / 密码都自动保存。
    await _persistInput();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _bundle = imported?.bundle;
      _usedUri = imported?.uri.toString();
      _error = failure;
    });
  }

  Future<void> _applyToSite(PtSite site) async {
    final CookieCloudBundle? bundle = _bundle;
    if (bundle == null) return;
    final String header = bundle.cookieHeaderForHost(site.host);
    if (header.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CookieCloud 数据里没有 ${site.host} 域名的 Cookie')),
      );
      return;
    }
    await ref.read(siteListProvider.notifier).saveCredential(site.id, <String, dynamic>{
      'type': SiteAuthType.cookie.name,
      'cookie': header,
      'source': 'cookiecloud',
      'cookieCloudHost': _uri?.toString() ?? _host.text.trim(),
      'importedAt': DateTime.now().toIso8601String(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已把 Cookie 导入「${site.name}」')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<PtSite> sites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];
    final CookieCloudBundle? bundle = _bundle;
    final PtSite? target = widget.siteId == null
        ? null
        : sites.where((PtSite s) => s.id == widget.siteId).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CookieCloud 导入'),
        leading: IconButton(icon: const Icon(Icons.close), tooltip: '取消', onPressed: _leave),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          if (target != null) ...<Widget>[
            SectionCard(
              title: '目标站点',
              subtitle: target.host,
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(target.name, style: theme.textTheme.bodyMedium)),
                  StatusBadge(
                    label: target.credentialConfigured ? '已有凭据' : '待录凭据',
                    tone: target.credentialConfigured ? StatusTone.ok : StatusTone.warning,
                    compact: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          SectionCard(
            title: 'CookieCloud 服务',
            subtitle: '端到端加密：密码只在本机参与解密，不会发送给服务端',
            child: Column(
              children: <Widget>[
                AddressInput(
                  label: '服务器地址',
                  keyPrefix: 'cookiecloud',
                  scheme: _scheme,
                  hostController: _host,
                  portController: _port,
                  pathController: _path,
                  onSchemeChanged: _onSchemeChanged,
                  snapshot: _probes.snapshot(_probeKey),
                  probing: _probes.isProbing(_probeKey),
                  hostHint: '192.168.1.10',
                  onEdited: _scheduleProbe,
                  onSubmitted: () => _probes.probeNow(_probeKey, _uri),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '反代挂在子路径下时填「子路径」（如 /cc）；协议与端口都可按实际部署修改，'
                  '填完会自动检测连通，地址后的标记即结论。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _uuid,
                  decoration: const InputDecoration(
                    labelText: 'UUID（浏览器扩展里的用户密钥）',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '端到端加密密码'),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _loading ? null : _fetch,
                      icon: const Icon(Icons.cloud_download_outlined, size: AppSizes.iconSm),
                      label: Text(_loading ? '拉取中…' : '拉取并解析'),
                    ),
                  ],
                ),
                if (_usedUri != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  Text('已从 $_usedUri 拉取', style: theme.textTheme.bodySmall),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(Icons.error_outline, size: AppSizes.iconSm, color: AppColors.danger),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(_error!, style: theme.textTheme.bodySmall)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (bundle != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '解析结果',
              subtitle: '${bundle.domainCount} 个域名 · ${bundle.cookieCount} 条 Cookie',
              child: Column(
                children: <Widget>[
                  for (final MapEntry<String, List<CookieCloudCookie>> entry in bundle.byDomain.entries)
                    _DomainRow(
                      domain: entry.key,
                      count: entry.value.length,
                      matchedSite: _matchSite(sites, entry.key),
                      onImport: _applyToSite,
                    ),
                  if (bundle.byDomain.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Text('解密成功，但没有解析到任何 Cookie', style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '提示：未匹配到已添加站点的域名需要先在「站点」里添加站点，再回到本页导入。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  /// 找出某个域名对应的已添加站点。
  static PtSite? _matchSite(List<PtSite> sites, String domain) {
    final String target = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (target.isEmpty) return null;
    return sites
        .where((PtSite s) =>
            s.host.toLowerCase() == target || s.host.toLowerCase().endsWith('.$target'))
        .firstOrNull;
  }
}

class _DomainRow extends StatelessWidget {
  const _DomainRow({
    required this.domain,
    required this.count,
    required this.matchedSite,
    required this.onImport,
  });

  final String domain;
  final int count;
  final PtSite? matchedSite;
  final Future<void> Function(PtSite site) onImport;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PtSite? site = matchedSite;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(domain, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.xxs),
                Text('$count 条 Cookie', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          if (site == null)
            const StatusBadge(label: '未匹配站点', tone: StatusTone.neutral, compact: true)
          else
            FilledButton.tonal(
              onPressed: () => onImport(site),
              child: Text('导入到 ${site.name}'),
            ),
        ],
      ),
    );
  }
}