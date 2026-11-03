import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/pt_site.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/cookiecloud_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
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
  final TextEditingController _host = TextEditingController();
  final TextEditingController _uuid = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _loading = false;
  String? _error;
  CookieCloudBundle? _bundle;

  @override
  void dispose() {
    _host.dispose();
    _uuid.dispose();
    _password.dispose();
    super.dispose();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.sites);
    }
  }

  Future<void> _fetch() async {
    final String host = _host.text.trim();
    final String uuid = _uuid.text.trim();
    final String password = _password.text;
    if (host.isEmpty || uuid.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写服务器地址、UUID 与密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _bundle = null;
    });
    try {
      final CookieCloudBundle bundle = await ref
          .read(cookieCloudServiceProvider)
          .fetchAndImport(host: host, uuid: uuid, password: password);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _bundle = bundle;
      });
    } on CookieCloudException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
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
      'cookieCloudHost': _host.text.trim(),
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
                TextField(
                  controller: _host,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'http://192.168.1.10:8088',
                  ),
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
                if (_error != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  Row(
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