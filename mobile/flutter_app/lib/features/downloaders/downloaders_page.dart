import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/direct/downloader_speed_history.dart';
import '../../core/models/downloader.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/storage/app_keys.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/mini_charts.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/stat_grid.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/swipe_action_row.dart';
import 'downloader_providers.dart';

/// 下载器列表展示模式：**列表图**（每行一个下载器，12 项数据网格）与
/// **网格图**（两列卡片，状态占比环 + 分类柱状 + 速率曲线）。
///
/// 切换按钮与「＋」都放在右上角刷新按钮一侧：右上角依次是
/// 「切换视图 / 刷新 / ＋ 添加下载器」，正文里不再放添加入口。
enum DownloadersViewMode {
  list('列表'),
  grid('网格');

  const DownloadersViewMode(this.label);

  final String label;

  static DownloadersViewMode fromName(String? value) => values.firstWhere(
        (DownloadersViewMode mode) => mode.name == value,
        orElse: () => DownloadersViewMode.list,
      );
}

/// 下载器页：多下载器清单与状态入口（需求 3）。
///
/// 本轮改造要点：
/// - 右上角新增视图切换与「＋」添加入口，移除正文里的「＋ 添加下载器」；
/// - 卡片数据来自直连采集（种子总数、各状态计数、限速、剩余空间、版本），
///   取不到就显示原因与「未采集」，不用 0 冒充；
/// - 每张卡片支持**左滑**露出「编辑 / 删除 / 默认」三个动作（列表模式下）；
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

  /// 展示模式（落盘，重进页面保持）。
  DownloadersViewMode _viewMode = DownloadersViewMode.list;

  PrefsStore get _prefs => ref.read(prefsStoreProvider);

  @override
  void initState() {
    super.initState();
    _viewMode = DownloadersViewMode.fromName(_prefs.getString(PrefKeys.downloadersViewMode));
  }

  void _toggleViewMode() {
    setState(() {
      _viewMode = _viewMode == DownloadersViewMode.list
          ? DownloadersViewMode.grid
          : DownloadersViewMode.list;
      // 切换视图时收起左滑，避免列表行与网格卡片状态互相干扰。
      _openId = null;
    });
    _prefs.setString(PrefKeys.downloadersViewMode, _viewMode.name);
  }

  /// 刷新：清单与各下载器的统计一起失效，速度采样则继续累积。
  void _refreshAll() {
    ref.invalidate(downloaderListProvider);
    ref.invalidate(downloaderStatsProvider);
  }

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

  void _addDownloader() => context.go(AppRoutes.downloaderAddPath);

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
    final bool grid = _viewMode == DownloadersViewMode.grid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('下载器'),
        actions: <Widget>[
          IconButton(
            tooltip: grid ? '切换为列表图' : '切换为网格图',
            onPressed: _toggleViewMode,
            icon: Icon(grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
          ),
          IconButton(
            tooltip: '刷新清单与数据',
            onPressed: _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '添加下载器',
            onPressed: _addDownloader,
            icon: const Icon(Icons.add),
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
                message: '尚未配置 NAS 服务地址：数据优先走 App 直连'
                    '（qBittorrent WebUI / Transmission RPC），'
                    'Aria2 等引擎由 NAS 后端转发。',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                grid
                    ? '网格图：状态占比环 / 分类柱状 / 速率曲线；点卡片进任务，⋮ 可编辑 · 删除 · 默认'
                    : '列表图：每站 12 项数据网格；左滑卡片可「编辑 / 删除 / 默认」',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          Expanded(
            child: listAsync.when(
              loading: () => const LoadingStateView(message: '正在读取下载器清单'),
              error: (Object error, StackTrace stackTrace) => ErrorStateView(
                message: '$error',
                onRetry: _refreshAll,
              ),
              data: (List<DownloaderConfig> list) => list.isEmpty
                  ? _emptyView(theme)
                  : (grid ? _gridView(theme, list) : _listView(theme, list)),
            ),
          ),
        ],
      ),
    );
  }

  /// 列表图：每行一个下载器，左滑露出「编辑 / 删除 / 默认」。
  Widget _listView(ThemeData theme, List<DownloaderConfig> list) {
    return ListView.separated(
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
              icon: config.isDefault ? Icons.star : Icons.star_border,
              enabled: !config.isDefault,
              onTap: () => _setDefault(config),
            ),
          ],
          child: _DownloaderTile(
            config: config,
            statsAsync: ref.watch(downloaderStatsProvider(config.id)),
            testing: _testingId == config.id,
            onTap: () => _openDetail(config),
            onTest: () => _test(config),
            onEdit: () => _edit(config),
            onSetDefault: () => _setDefault(config),
            onDelete: () => _confirmDelete(config),
          ),
        );
      },
    );
  }

  /// 网格图：两列等宽卡片，行始终铺满（不会出现半行留空）。
  Widget _gridView(ThemeData theme, List<DownloaderConfig> list) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: AppSpacing.cardGap,
        mainAxisSpacing: AppSpacing.cardGap,
        childAspectRatio: 0.62,
      ),
      itemCount: list.length,
      itemBuilder: (BuildContext context, int index) {
        final DownloaderConfig config = list[index];
        return _DownloaderGridTile(
          config: config,
          statsAsync: ref.watch(downloaderStatsProvider(config.id)),
          speedHistory: ref.watch(downloaderSpeedHistoryProvider).of(config.id),
          testing: _testingId == config.id,
          onTap: () => _openDetail(config),
          onTest: () => _test(config),
          onEdit: () => _edit(config),
          onSetDefault: () => _setDefault(config),
          onDelete: () => _confirmDelete(config),
        );
      },
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
              '点右上角「＋」添加 qBittorrent、Transmission、Aria2 等多个下载器；'
              '任务列表与暂停 / 继续 / 删除操作在下载器详情里集中处理。',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// 统计项文案：限速 0 = 不限，null = 未采集（两者含义不同，不能都写成 0）。
String downloaderLimitLabel(int? bytesPerSecond) {
  if (bytesPerSecond == null) return '未采集';
  if (bytesPerSecond == 0) return '不限';
  return formatSpeed(bytesPerSecond);
}

/// 下载器卡片上的 12 项数据（4 行 × 3 列的等宽网格，行行铺满）。
List<StatItem> downloaderStatItems(DownloaderStats stats) {
  return <StatItem>[
    StatItem(label: '种子总数', value: '${stats.total}'),
    StatItem(
      label: '正在做种',
      value: '${stats.countOf(TaskState.seeding)}',
      tone: AppColors.brand,
    ),
    StatItem(
      label: '正在下载',
      value: '${stats.countOf(TaskState.downloading)}',
      tone: AppColors.info,
    ),
    StatItem(label: '已完成', value: '${stats.countOf(TaskState.completed)}'),
    StatItem(label: '已暂停', value: '${stats.countOf(TaskState.paused)}'),
    StatItem(label: '排队中', value: '${stats.countOf(TaskState.queued)}'),
    StatItem(
      label: '校验中',
      value: '${stats.countOf(TaskState.checking)}',
      tone: AppColors.warning,
    ),
    StatItem(
      label: '错误',
      value: '${stats.countOf(TaskState.error)}',
      tone: AppColors.danger,
    ),
    StatItem(label: '未知', value: '${stats.countOf(TaskState.unknown)}'),
    StatItem(
      label: '上传限速',
      value: downloaderLimitLabel(stats.uploadLimitBytes),
      collected: stats.uploadLimitBytes != null,
    ),
    StatItem(
      label: '下载限速',
      value: downloaderLimitLabel(stats.downloadLimitBytes),
      collected: stats.downloadLimitBytes != null,
    ),
    StatItem(
      label: '剩余空间',
      value: stats.freeSpaceBytes == null ? '未采集' : formatBytes(stats.freeSpaceBytes!),
      collected: stats.freeSpaceBytes != null,
    ),
  ];
}

/// 状态占比环的分片：做种 / 下载 / 已完成 / 暂停 / 错误 / 其他。
List<({String label, int value, Color color})> downloaderStateSlices(DownloaderStats stats) {
  final int others = stats.countOf(TaskState.queued) +
      stats.countOf(TaskState.checking) +
      stats.countOf(TaskState.unknown);
  return <({String label, int value, Color color})>[
    (label: '做种', value: stats.countOf(TaskState.seeding), color: AppColors.brand),
    (label: '下载', value: stats.countOf(TaskState.downloading), color: AppColors.info),
    (label: '已完成', value: stats.countOf(TaskState.completed), color: AppColors.textMuted),
    (label: '暂停', value: stats.countOf(TaskState.paused), color: AppColors.warning),
    (label: '错误', value: stats.countOf(TaskState.error), color: AppColors.danger),
    (label: '其他', value: others, color: AppColors.textSecondary),
  ];
}

/// 分类柱状图的数据：按任务数倒序。
List<MapEntry<String, int>> downloaderCategoryEntries(DownloaderStats stats) {
  final List<MapEntry<String, int>> entries = stats.categoryCounts.entries.toList();
  entries.sort((MapEntry<String, int> a, MapEntry<String, int> b) {
    final int byValue = b.value.compareTo(a.value);
    return byValue != 0 ? byValue : a.key.compareTo(b.key);
  });
  return entries;
}

/// 下载器的「测试 / 编辑 / 默认 / 删除」四个动作（列表与网格共用）。
List<PopupMenuEntry<String>> downloaderMenuItems(DownloaderConfig config) =>
    <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(value: 'test', child: Text('测试连接')),
      const PopupMenuItem<String>(value: 'edit', child: Text('编辑配置')),
      PopupMenuItem<String>(
        value: 'default',
        enabled: !config.isDefault,
        child: Text(config.isDefault ? '已是默认下载器' : '设为默认下载器'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(value: 'delete', child: Text('删除下载器')),
    ];

/// 下载器卡片 ⋮ 菜单的统一处理（列表与网格共用同一套动作）。
void runDownloaderMenuAction(
  String action, {
  required VoidCallback onTest,
  required VoidCallback onEdit,
  required VoidCallback onSetDefault,
  required VoidCallback onDelete,
}) {
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
}

/// 引擎版本徽章（未采集时不显示，避免出现「v 」这种空壳）。
Widget? downloaderVersionBadge(DownloaderStats? stats) {
  final String version = stats?.version.trim() ?? '';
  if (version.isEmpty) return null;
  return StatusBadge(label: 'v$version', tone: StatusTone.info, compact: true);
}

/// 采集失败时的一段说明：把原因显示出来，而不是把失败画成 0。
Widget downloaderStatsNotice(ThemeData theme, DownloaderStats stats) {
  final bool sampled = stats.sampled;
  final String text = sampled
      ? '部分引擎字段未采集（限速 / 剩余空间 / 版本）'
      : (stats.failureMessage.isEmpty ? '数据未采集' : '数据未采集：${stats.failureMessage}');
  return Text(
    text,
    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
  );
}

class _DownloaderTile extends StatelessWidget {
  const _DownloaderTile({
    required this.config,
    required this.statsAsync,
    required this.testing,
    required this.onTap,
    required this.onTest,
    required this.onEdit,
    required this.onSetDefault,
    required this.onDelete,
  });

  final DownloaderConfig config;
  final AsyncValue<DownloaderStats> statsAsync;
  final bool testing;
  final VoidCallback onTap;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onSetDefault;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DownloaderStats? stats = statsAsync.valueOrNull;

    return SectionCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DownloaderAvatar(kind: config.kind),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            config.name,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (downloaderVersionBadge(stats) != null) ...<Widget>[
                          const SizedBox(width: AppSpacing.xs),
                          downloaderVersionBadge(stats)!,
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(config.host, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: AppSpacing.xs),
                    DownloaderBadges(config: config),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  if (testing)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    PopupMenuButton<String>(
                      tooltip: '更多操作',
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_vert, size: AppSizes.iconMd),
                      onSelected: (String action) => runDownloaderMenuAction(
                        action,
                        onTest: onTest,
                        onEdit: onEdit,
                        onSetDefault: onSetDefault,
                        onDelete: onDelete,
                      ),
                      itemBuilder: (BuildContext context) => downloaderMenuItems(config),
                    ),
                  if (stats != null && stats.sampled)
                    Text(
                      '↑ ${formatSpeed(stats.uploadSpeed)}',
                      style: theme.textTheme.labelSmall?.copyWith(color: AppColors.brand),
                    ),
                  if (stats != null && stats.sampled)
                    Text(
                      '↓ ${formatSpeed(stats.downloadSpeed)}',
                      style: theme.textTheme.labelSmall?.copyWith(color: AppColors.info),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (statsAsync.isLoading && stats == null)
            Text('正在读取数据…', style: theme.textTheme.bodySmall)
          else if (stats != null) ...<Widget>[
            if (!stats.sampled) ...<Widget>[
              downloaderStatsNotice(theme, stats),
              const SizedBox(height: AppSpacing.xs),
            ],
            StatGrid(items: downloaderStatItems(stats)),
            if (stats.sampled && stats.version.isEmpty && stats.freeSpaceBytes == null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: downloaderStatsNotice(theme, stats),
              ),
          ],
        ],
      ),
    );
  }
}

/// 网格图里的卡片：两列等宽，图表按站并排；高度由网格单元给定，内容自适应。
class _DownloaderGridTile extends StatelessWidget {
  const _DownloaderGridTile({
    required this.config,
    required this.statsAsync,
    required this.speedHistory,
    required this.testing,
    required this.onTap,
    required this.onTest,
    required this.onEdit,
    required this.onSetDefault,
    required this.onDelete,
  });

  final DownloaderConfig config;
  final AsyncValue<DownloaderStats> statsAsync;
  final List<DownloaderSpeedSample> speedHistory;
  final bool testing;
  final VoidCallback onTap;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onSetDefault;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DownloaderStats? stats = statsAsync.valueOrNull;

    final Widget menu = testing
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : PopupMenuButton<String>(
            tooltip: '更多操作',
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.more_vert, size: AppSizes.iconMd),
            onSelected: (String action) => runDownloaderMenuAction(
              action,
              onTest: onTest,
              onEdit: onEdit,
              onSetDefault: onSetDefault,
              onDelete: onDelete,
            ),
            itemBuilder: (BuildContext context) => downloaderMenuItems(config),
          );

    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: AppRadius.cardBorder,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: theme.colorScheme.outline),
          ),
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  DownloaderAvatar(kind: config.kind, size: 32),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      config.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  menu,
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                config.host,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              DownloaderBadges(config: config),
              const SizedBox(height: AppSpacing.sm),
              if (statsAsync.isLoading && stats == null)
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text('正在读取数据…', style: theme.textTheme.bodySmall),
                  ),
                )
              else if (stats != null && !stats.sampled)
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: downloaderStatsNotice(theme, stats),
                  ),
                )
              else if (stats != null) ...<Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    MiniDonut(
                      slices: downloaderStateSlices(stats),
                      size: 54,
                      thickness: 8,
                      centerLabel: '${stats.total}',
                      centerCaption: '种子',
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '↑ ${formatSpeed(stats.uploadSpeed)}',
                            style: theme.textTheme.labelSmall?.copyWith(color: AppColors.brand),
                          ),
                          Text(
                            '↓ ${formatSpeed(stats.downloadSpeed)}',
                            style: theme.textTheme.labelSmall?.copyWith(color: AppColors.info),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          MiniBarChart(
                            entries: downloaderCategoryEntries(stats),
                            color: AppColors.brand,
                            barHeight: 26,
                            maxBars: 4,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                // 速率曲线：只有真实采样 ≥2 点才画线（采样不足时显示「采样中」）。
                Expanded(
                  child: MiniSparkline(
                    values: speedHistory
                        .map((DownloaderSpeedSample s) => s.download.toDouble())
                        .toList(growable: false),
                    color: AppColors.info,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 下载器头像：按引擎取字标，避免为每个引擎准备一套图标资源。
class DownloaderAvatar extends StatelessWidget {
  const DownloaderAvatar({super.key, required this.kind, this.size = 40});

  final DownloaderKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String mark = switch (kind) {
      DownloaderKind.qbittorrent => 'qb',
      DownloaderKind.transmission => 'tr',
      DownloaderKind.aria2 => 'a2',
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
      ),
      child: Text(
        mark,
        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 下载器状态徽章行（列表与网格共用）：连接状态、默认、类型、账号、停用。
class DownloaderBadges extends StatelessWidget {
  const DownloaderBadges({super.key, required this.config});

  final DownloaderConfig config;

  static StatusTone _tone(DownloaderHealth health) => switch (health) {
        DownloaderHealth.ok => StatusTone.ok,
        DownloaderHealth.warning => StatusTone.warning,
        DownloaderHealth.danger => StatusTone.danger,
        DownloaderHealth.unknown => StatusTone.neutral,
      };

  @override
  Widget build(BuildContext context) {
    return Wrap(
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
    );
  }
}