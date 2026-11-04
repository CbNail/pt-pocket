import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/downloader.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/swipe_action_row.dart';
import 'downloader_providers.dart';

/// 下载器页：多下载器清单与状态入口（需求 3）。
///
/// 本轮改造要点：
/// - 每张卡片支持**左滑**露出「编辑 / 删除 / 默认」三个动作，右上角三点菜单保留；
/// - 「默认」是互斥标记：设为默认后其它下载器自动取消，推送时未指定目标就走默认下载器；
/// - 连接是否正常在外层用状态圆点表达，进入详情后不再重复展示连接信息与操作框。
class DownloadersPage extends ConsumerStatefulWidget {
  const DownloadersPage({super.key});

  @override
  ConsumerState<DownloadersPage> createState() => _DownloadersPageState();
}

class _DownloadersPageState extends ConsumerState<DownloadersPage> {
  String? _testingId;

  /// 当前左滑展开的那一行；同一时刻只允许一行展开。
  String? _openId;

  Future<void> _test(DownloaderConfig config) async {
    setState(() => _testingId = config.id);
    final SiteProbeResult result = await ref.read(downloaderProbeProvider)(config.baseUrl);
    await ref.read(downloaderListProvider.notifier).recordProbe(config.id, result.isSuccess);
    if (!mounted) return;
    setState(() => _testingId = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${config.name}：${result.outcome.label} · ${result.message}')),
    );
  }

  Future<void> _setDefault(DownloaderConfig config) async {
    if (config.isDefault) {
      _snack('「${config.name}」已经是默认下载器');
      return;
    }
    await ref.read(downloaderListProvider.notifier).setDefault(config.id);
    if (!mounted) return;
    _snack('已把「${config.name}」设为默认下载器');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openDetail(DownloaderConfig config) {
    // 有行处于展开状态时，先收起，避免“想收卡片却进了详情”。
    if (_openId != null) {
      setState(() => _openId = null);
      return;
    }
    context.go(AppRoutes.downloaderDetailPath(config.id));
  }

  void _edit(DownloaderConfig config) {
    context.go(AppRoutes.downloaderEditPath(config.id));
  }

  Future<void> _confirmDelete(DownloaderConfig config) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除下载器'),
        content: Text('将删除「${config.name}」及其在本机保存的账号密码，操作不可恢复。'),
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
    await ref.read(downloaderListProvider.notifier).remove(config.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除「${config.name}」')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;
    final AsyncValue<List<DownloaderConfig>> listAsync = ref.watch(downloaderListProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('下载器'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新清单',
            onPressed: () => ref.invalidate(downloaderListProvider),
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
                message: '尚未配置 NAS 服务地址；下载器任务的获取与操作由 NAS 后端统一调度。',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('左滑卡片可「编辑 / 删除 / 默认」', style: theme.textTheme.bodySmall),
            ),
          ),
          Expanded(
            child: listAsync.when(
              loading: () => const LoadingStateView(message: '正在读取下载器清单'),
              error: (Object error, StackTrace stackTrace) => ErrorStateView(
                message: '$error',
                onRetry: () => ref.invalidate(downloaderListProvider),
              ),
              data: (List<DownloaderConfig> list) => list.isEmpty
                  ? _emptyView(theme)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.sm,
                        AppSpacing.lg,
                        AppSpacing.xxl,
                      ),
                      itemCount: list.length,
                      separatorBuilder: (BuildContext context, int index) =>
                          const SizedBox(height: AppSpacing.cardGap),
                      itemBuilder: (BuildContext context, int index) {
                        final DownloaderConfig config = list[index];
                        return SwipeActionRow(
                          itemKey: config.id,
                          openKey: _openId,
                          onOpen: (String? key) => setState(() => _openId = key),
                          actions: <SwipeActionButton>[
                            SwipeActionButton(
                              label: '编辑',
                              icon: Icons.edit_outlined,
                              onTap: () => _edit(config),
                            ),
                            SwipeActionButton(
                              label: '删除',
                              icon: Icons.delete_outline,
                              background: theme.colorScheme.errorContainer,
                              foreground: theme.colorScheme.onErrorContainer,
                              onTap: () => _confirmDelete(config),
                            ),
                            SwipeActionButton(
                              label: '默认',
                              icon: config.isDefault
                                  ? Icons.star
                                  : Icons.star_border,
                              enabled: !config.isDefault,
                              onTap: () => _setDefault(config),
                            ),
                          ],
                          child: _DownloaderTile(
                            config: config,
                            testing: _testingId == config.id,
                            onTap: () => _openDetail(config),
                            onTest: () => _test(config),
                            onEdit: () => _edit(config),
                            onSetDefault: () => _setDefault(config),
                            onDelete: () => _confirmDelete(config),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(AppRoutes.downloaderAddPath),
        icon: const Icon(Icons.add),
        label: const Text('添加下载器'),
      ),
    );
  }

  Widget _emptyView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.download_outlined, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('还没有添加下载器', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '可添加 qBittorrent、Transmission、Aria2 等多个下载器；'
              '任务列表与暂停 / 继续 / 删除操作在此集中处理。',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: () => context.go(AppRoutes.downloaderAddPath),
              icon: const Icon(Icons.add, size: AppSizes.iconSm),
              label: const Text('添加下载器'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloaderTile extends StatelessWidget {
  const _DownloaderTile({
    required this.config,
    required this.testing,
    required this.onTap,
    required this.onTest,
    required this.onEdit,
    required this.onSetDefault,
    required this.onDelete,
  });

  final DownloaderConfig config;
  final bool testing;
  final VoidCallback onTap;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onSetDefault;
  final VoidCallback onDelete;

  static StatusTone _tone(DownloaderHealth health) => switch (health) {
        DownloaderHealth.ok => StatusTone.ok,
        DownloaderHealth.warning => StatusTone.warning,
        DownloaderHealth.danger => StatusTone.danger,
        DownloaderHealth.unknown => StatusTone.neutral,
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
            child: Icon(Icons.download_outlined, size: AppSizes.iconMd, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(config.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.xxs),
                Text(config.host, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xxs,
                  children: <Widget>[
                    // 连接是否正常：这个圆点就是外层唯一的连接状态表达。
                    StatusBadge(label: config.health.label, tone: _tone(config.health), compact: true),
                    if (config.isDefault)
                      const StatusBadge(
                        label: '默认',
                        tone: StatusTone.info,
                        icon: Icons.star,
                        compact: true,
                      ),
                    StatusBadge(label: config.kind.label, tone: StatusTone.info, compact: true),
                    StatusBadge(
                      label: config.credentialConfigured ? '账号已录入' : '待录账号',
                      tone: config.credentialConfigured ? StatusTone.ok : StatusTone.warning,
                      compact: true,
                    ),
                    if (!config.enabled)
                      const StatusBadge(label: '已停用', tone: StatusTone.neutral, compact: true),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (testing)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else
            PopupMenuButton<String>(
              tooltip: '更多操作',
              icon: const Icon(Icons.more_vert, size: AppSizes.iconMd),
              onSelected: (String action) {
                switch (action) {
                  case 'test':
                    onTest();
                  case 'edit':
                    onEdit();
                  case 'default':
                    onSetDefault();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(value: 'test', child: Text('测试连接')),
                const PopupMenuItem<String>(value: 'edit', child: Text('编辑配置')),
                PopupMenuItem<String>(
                  value: 'default',
                  enabled: !config.isDefault,
                  child: Text(config.isDefault ? '已是默认下载器' : '设为默认下载器'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(value: 'delete', child: Text('删除下载器')),
              ],
            ),
        ],
      ),
    );
  }
}