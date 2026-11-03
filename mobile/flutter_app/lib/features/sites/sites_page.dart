import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/pt_site.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import 'site_providers.dart';

/// 站点页：站点清单、凭据状态、连接测试与导入入口（需求 1、需求 17 的交互基础）。
class SitesPage extends ConsumerStatefulWidget {
  const SitesPage({super.key});

  @override
  ConsumerState<SitesPage> createState() => _SitesPageState();
}

class _SitesPageState extends ConsumerState<SitesPage> {
  final TextEditingController _query = TextEditingController();
  bool _favoriteFirst = false;
  String? _testingId;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<PtSite> _visible(List<PtSite> sites) {
    final String keyword = _query.text.trim().toLowerCase();
    final List<PtSite> list = sites
        .where((PtSite s) =>
            keyword.isEmpty ||
            s.name.toLowerCase().contains(keyword) ||
            s.host.toLowerCase().contains(keyword))
        .toList();
    if (_favoriteFirst) {
      list.sort((PtSite a, PtSite b) {
        if (a.favorite == b.favorite) return a.name.compareTo(b.name);
        return a.favorite ? -1 : 1;
      });
    }
    return list;
  }

  Future<void> _test(PtSite site) async {
    setState(() => _testingId = site.id);
    final SiteProbeResult result = await ref.read(siteProbeProvider)(site.baseUrl);
    await ref.read(siteListProvider.notifier).recordProbe(site.id, result);
    if (!mounted) return;
    setState(() => _testingId = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${site.name}：${result.outcome.label} · ${result.message}')),
    );
  }

  Future<void> _confirmDelete(PtSite site) async {
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除「${site.name}」')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;
    final AsyncValue<List<PtSite>> sitesAsync = ref.watch(siteListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('站点'),
        actions: <Widget>[
          PopupMenuButton<bool>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            initialValue: _favoriteFirst,
            onSelected: (bool favoriteFirst) => setState(() => _favoriteFirst = favoriteFirst),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<bool>>[
              CheckedPopupMenuItem<bool>(
                value: true,
                checked: _favoriteFirst,
                child: const Text('收藏优先'),
              ),
              CheckedPopupMenuItem<bool>(
                value: false,
                checked: !_favoriteFirst,
                child: const Text('按名称'),
              ),
            ],
          ),
          IconButton(
            tooltip: '刷新清单',
            onPressed: () => ref.invalidate(siteListProvider),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!nasConfigured)
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
              child: PartialResultBanner(
                message: '尚未配置 NAS 服务地址；站点的签到、巡检与聚合搜索在完成服务配对后启用。',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
            child: TextField(
              controller: _query,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索已添加的站点',
                prefixIcon: const Icon(Icons.search, size: AppSizes.iconLg),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: AppSizes.iconMd),
                        onPressed: () {
                          _query.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: sitesAsync.when(
              loading: () => const LoadingStateView(message: '正在读取站点清单'),
              error: (Object error, StackTrace stackTrace) => ErrorStateView(
                message: '$error',
                onRetry: () => ref.invalidate(siteListProvider),
              ),
              data: (List<PtSite> sites) => sites.isEmpty ? _emptyView(context) : _listView(sites),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(AppRoutes.siteAddPath),
        icon: const Icon(Icons.add),
        label: const Text('添加站点'),
      ),
    );
  }

  Widget _emptyView(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.dns_outlined, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('还没有添加站点', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '添加站点后可录入 Cookie / Passkey / API Key，做连接测试，'
              '或从 CookieCloud 与 PTD 备份批量恢复。',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: () => context.go(AppRoutes.siteAddPath),
              icon: const Icon(Icons.add, size: AppSizes.iconSm),
              label: const Text('添加站点'),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: () => context.go(AppRoutes.siteCookieCloudPath),
              icon: const Icon(Icons.cloud_download_outlined, size: AppSizes.iconSm),
              label: const Text('CookieCloud 一键导入'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: () => context.go(AppRoutes.sitePtdImportPath),
              icon: const Icon(Icons.file_upload_outlined, size: AppSizes.iconSm),
              label: const Text('导入 PTD 备份'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listView(List<PtSite> sites) {
    final List<PtSite> visible = _visible(sites);
    if (visible.isEmpty) {
      return const EmptyStateView(
        icon: Icons.search_off,
        title: '没有匹配的站点',
        message: '换个关键词，或清空搜索框。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
      itemCount: visible.length,
      separatorBuilder: (BuildContext context, int index) => const SizedBox(height: AppSpacing.cardGap),
      itemBuilder: (BuildContext context, int index) {
        final PtSite site = visible[index];
        return _SiteTile(
          site: site,
          testing: _testingId == site.id,
          onTap: () => context.go(AppRoutes.siteDetailPath(site.id)),
          onTest: () => _test(site),
          onToggleFavorite: () => ref.read(siteListProvider.notifier).toggleFavorite(site.id),
          onDelete: () => _confirmDelete(site),
        );
      },
    );
  }
}

/// 站点列表项。
class _SiteTile extends StatelessWidget {
  const _SiteTile({
    required this.site,
    required this.testing,
    required this.onTap,
    required this.onTest,
    required this.onToggleFavorite,
    required this.onDelete,
  });

  final PtSite site;
  final bool testing;
  final VoidCallback onTap;
  final VoidCallback onTest;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;

  static StatusTone _tone(SiteHealth health) => switch (health) {
        SiteHealth.ok => StatusTone.ok,
        SiteHealth.warning => StatusTone.warning,
        SiteHealth.danger => StatusTone.danger,
        SiteHealth.unknown => StatusTone.neutral,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SectionCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
            ),
            child: Icon(Icons.dns_outlined, size: AppSizes.iconMd, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        site.name,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (site.favorite) ...<Widget>[
                      const SizedBox(width: AppSpacing.xs),
                      const Icon(Icons.star, size: AppSizes.iconSm, color: AppColors.warning),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(site.host, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xxs,
                  children: <Widget>[
                    StatusBadge(label: site.health.label, tone: _tone(site.health), compact: true),
                    StatusBadge(label: site.framework.label, tone: StatusTone.info, compact: true),
                    StatusBadge(
                      label: site.credentialConfigured ? '凭据已录入' : '待录凭据',
                      tone: site.credentialConfigured ? StatusTone.ok : StatusTone.warning,
                      compact: true,
                    ),
                    if (!site.enabled)
                      const StatusBadge(label: '已停用', tone: StatusTone.neutral, compact: true),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (testing)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            PopupMenuButton<String>(
              tooltip: '更多操作',
              icon: const Icon(Icons.more_vert, size: AppSizes.iconMd),
              onSelected: (String action) {
                switch (action) {
                  case 'test':
                    onTest();
                  case 'favorite':
                    onToggleFavorite();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(value: 'test', child: Text('测试连接')),
                PopupMenuItem<String>(
                  value: 'favorite',
                  child: Text(site.favorite ? '取消收藏' : '收藏'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(value: 'delete', child: Text('删除站点')),
              ],
            ),
        ],
      ),
    );
  }
}