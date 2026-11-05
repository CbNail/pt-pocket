import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/pt_site.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import 'site_providers.dart';
import 'widgets/credential_form.dart';

/// 站点编辑：站点信息、连接测试、凭据管理与参与范围（需求 1）。
///
/// 说明：原「导入与登录」模块已移除（批量导入入口在站点列表的更多菜单里）；
/// 需要手动登录抓 Cookie 时，用凭据区里的「内置浏览器登录」按钮，不额外占一个分区。
class SiteDetailPage extends ConsumerStatefulWidget {
  const SiteDetailPage({super.key, required this.siteId});

  final String siteId;

  @override
  ConsumerState<SiteDetailPage> createState() => _SiteDetailPageState();
}

class _SiteDetailPageState extends ConsumerState<SiteDetailPage> {
  SiteProbeResult? _probeResult;
  bool _probing = false;

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.sites);
    }
  }

  Future<void> _test(PtSite site) async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final SiteProbeResult result = await ref.read(siteProbeProvider)(site.baseUrl);
    await ref.read(siteListProvider.notifier).recordProbe(site.id, result);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = result;
    });
  }

  Future<void> _editCredential(PtSite site) async {
    final Map<String, dynamic>? current =
        await ref.read(siteRepositoryProvider).readCredential(site.id);
    if (!mounted) return;

    final Map<String, dynamic>? result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _CredentialSheet(
        authType: site.authType,
        initial: current,
      ),
    );
    if (result == null) return;
    await ref.read(siteListProvider.notifier).saveCredential(site.id, result);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('凭据已保存到本机安全存储')),
    );
  }

  Future<void> _clearCredential(PtSite site) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('清除凭据'),
        content: Text('将删除「${site.name}」在本机保存的凭据，站点配置本身保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(siteListProvider.notifier).clearCredential(site.id);
  }

  Future<void> _delete(PtSite site) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除站点'),
        content: Text('将删除「${site.name}」及其在本机保存的凭据，操作不可恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(siteListProvider.notifier).remove(site.id);
    if (!mounted) return;
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PtSite? site = ref.watch(siteByIdProvider(widget.siteId));
    final AsyncValue<Map<String, dynamic>?> credentialAsync =
        ref.watch(siteCredentialProvider(widget.siteId));

    if (site == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('编辑站点'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        ),
        body: ErrorStateView(
          title: '站点不存在',
          message: '该站点可能已被删除，返回列表重新选择。',
          onRetry: _leave,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('编辑 · ${site.name}'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        actions: <Widget>[
          IconButton(
            tooltip: site.favorite ? '取消收藏' : '收藏',
            onPressed: () => ref.read(siteListProvider.notifier).toggleFavorite(site.id),
            icon: Icon(site.favorite ? Icons.star : Icons.star_border),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '站点信息',
            subtitle: site.baseUrl,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _InfoRow(label: '适配定义', value: site.framework.label),
                _InfoRow(label: '认证方式', value: site.authType.label),
                _InfoRow(
                  label: '最近测试',
                  value: site.lastTestedAt == null ? '未测试' : _formatTime(site.lastTestedAt!),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '连接测试',
            subtitle: '探测站点地址可达性；凭据校验由服务端适配器完成',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: _probing ? null : () => _test(site),
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
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '凭据',
            subtitle: '凭据只保存在本机安全存储',
            child: credentialAsync.when(
              loading: () => const LoadingStateView(message: '读取凭据状态'),
              error: (Object error, StackTrace stackTrace) => Text('读取失败：$error', style: theme.textTheme.bodySmall),
              data: (Map<String, dynamic>? credential) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      StatusBadge(
                        label: credential == null ? '未录入' : '已录入',
                        tone: credential == null ? StatusTone.warning : StatusTone.ok,
                        compact: true,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(describeCredential(credential), style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: () => _editCredential(site),
                        icon: const Icon(Icons.edit_outlined, size: AppSizes.iconSm),
                        label: Text(credential == null ? '录入凭据' : '更新凭据'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => context.go(
                          AppRoutes.siteVaultwardenPath(
                            siteId: site.id,
                            initialUrl: site.baseUrl,
                          ),
                        ),
                        icon: const Icon(Icons.login_outlined, size: AppSizes.iconSm),
                        label: const Text('内置浏览器登录'),
                      ),
                      if (credential != null)
                        TextButton.icon(
                          onPressed: () => _clearCredential(site),
                          icon: const Icon(Icons.delete_outline, size: AppSizes.iconSm),
                          label: const Text('清除凭据'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '参与范围',
            child: Column(
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: site.enabled,
                  title: const Text('参与聚合搜索与巡检'),
                  subtitle: const Text('关闭后该站点不参与搜索、签到与状态巡检'),
                  onChanged: (_) => ref.read(siteListProvider.notifier).toggleEnabled(site.id),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: site.favorite,
                  title: const Text('收藏站点'),
                  subtitle: const Text('收藏站点在列表中优先展示'),
                  onChanged: (_) => ref.read(siteListProvider.notifier).toggleFavorite(site.id),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: () => _delete(site),
            icon: const Icon(Icons.delete_outline, size: AppSizes.iconSm),
            label: const Text('删除站点'),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 凭据编辑面板：按认证方式采集输入并返回组装好的凭据。
class _CredentialSheet extends StatefulWidget {
  const _CredentialSheet({required this.authType, this.initial});

  final SiteAuthType authType;
  final Map<String, dynamic>? initial;

  @override
  State<_CredentialSheet> createState() => _CredentialSheetState();
}

class _CredentialSheetState extends State<_CredentialSheet> {
  late final TextEditingController _cookie =
      TextEditingController(text: widget.initial?['cookie']?.toString() ?? '');
  late final TextEditingController _secret = TextEditingController(
    text: widget.initial?[widget.authType.name]?.toString() ?? '',
  );
  late final TextEditingController _username =
      TextEditingController(text: widget.initial?['username']?.toString() ?? '');
  late final TextEditingController _password =
      TextEditingController(text: widget.initial?['password']?.toString() ?? '');

  @override
  void dispose() {
    _cookie.dispose();
    _secret.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final Map<String, dynamic>? credential = buildCredentialMap(
      widget.authType,
      cookie: _cookie.text,
      secret: _secret.text,
      username: _username.text,
      password: _password.text,
    );
    if (credential == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写凭据内容')),
      );
      return;
    }
    Navigator.of(context).pop(credential);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('${widget.authType.label} 凭据', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(widget.authType.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.lg),
            CredentialFields(
              authType: widget.authType,
              cookieController: _cookie,
              secretController: _secret,
              usernameController: _username,
              passwordController: _password,
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FilledButton(
                    onPressed: _submit,
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}