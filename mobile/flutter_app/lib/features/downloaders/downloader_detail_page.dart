import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/downloader.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/downloader_api.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import 'downloader_providers.dart';

/// 下载器详情：连接信息、任务列表与任务操作（需求 3）。
///
/// 任务数据与操作统一经 NAS 后端接口下发；服务端适配器负责与
/// qBittorrent / Transmission / Aria2 等引擎交互。
class DownloaderDetailPage extends ConsumerStatefulWidget {
  const DownloaderDetailPage({super.key, required this.downloaderId});

  final String downloaderId;

  @override
  ConsumerState<DownloaderDetailPage> createState() => _DownloaderDetailPageState();
}

class _DownloaderDetailPageState extends ConsumerState<DownloaderDetailPage> {
  SiteProbeResult? _probeResult;
  bool _probing = false;
  String? _busyHash;

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

  Future<void> _test(DownloaderConfig config) async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final SiteProbeResult result = await ref.read(downloaderProbeProvider)(config.baseUrl);
    await ref.read(downloaderListProvider.notifier).recordProbe(config.id, result.isSuccess);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = result;
    });
  }

  Future<void> _runAction(DownloaderTask task, String action) async {
    final DownloaderApi api = ref.read(downloaderApiProvider);
    setState(() => _busyHash = task.hash);
    try {
      switch (action) {
        case 'pause':
          await api.pause(widget.downloaderId, <String>[task.hash]);
          _snack('已下发暂停');
        case 'resume':
          await api.resume(widget.downloaderId, <String>[task.hash]);
          _snack('已下发继续');
      }
      ref.invalidate(downloaderTasksProvider(widget.downloaderId));
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    } finally {
      if (mounted) setState(() => _busyHash = null);
    }
  }

  Future<void> _removeTask(DownloaderTask task) async {
    final bool? deleteFiles = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('移除任务'),
        content: Text('「${task.name}」：只移除任务记录，还是同时删除已下载的数据？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('仅移除任务'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除任务与文件'),
          ),
        ],
      ),
    );
    if (deleteFiles == null) return;

    setState(() => _busyHash = task.hash);
    try {
      await ref
          .read(downloaderApiProvider)
          .remove(widget.downloaderId, <String>[task.hash], deleteFiles: deleteFiles);
      _snack(deleteFiles ? '已下发删除任务与文件' : '已下发移除任务');
      ref.invalidate(downloaderTasksProvider(widget.downloaderId));
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    } finally {
      if (mounted) setState(() => _busyHash = null);
    }
  }

  Future<void> _confirmDeleteDownloader(DownloaderConfig config) async {
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
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DownloaderConfig? config = ref.watch(downloaderByIdProvider(widget.downloaderId));

    if (config == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('下载器详情'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        ),
        body: ErrorStateView(
          title: '下载器不存在',
          message: '该下载器可能已被删除，返回列表重新选择。',
          onRetry: _leave,
        ),
      );
    }

    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;
    final AsyncValue<List<DownloaderTask>> tasksAsync =
        ref.watch(downloaderTasksProvider(widget.downloaderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(config.name),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新任务',
            onPressed: () => ref.invalidate(downloaderTasksProvider(widget.downloaderId)),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '连接信息',
            subtitle: config.baseUrl,
            trailing: StatusBadge(
              label: config.health.label,
              tone: config.health == DownloaderHealth.ok ? StatusTone.ok : StatusTone.neutral,
              compact: true,
            ),
            child: Column(
              children: <Widget>[
                _InfoRow(label: '类型', value: config.kind.label),
                _InfoRow(label: '账号', value: config.username.isEmpty ? '未填写' : config.username),
                _InfoRow(
                  label: '密码',
                  value: config.credentialConfigured ? '已保存' : '未保存',
                ),
                _InfoRow(
                  label: '默认目录',
                  value: config.defaultSavePath.isEmpty ? '未设置' : config.defaultSavePath,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '操作',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      onPressed: _probing ? null : () => _test(config),
                      icon: const Icon(Icons.network_check, size: AppSizes.iconSm),
                      label: Text(_probing ? '测试中…' : '测试连接'),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    OutlinedButton.icon(
                      onPressed: () => context.go(
                        '${AppRoutes.downloaderAddPath}?downloaderId=${config.id}',
                      ),
                      icon: const Icon(Icons.edit_outlined, size: AppSizes.iconSm),
                      label: const Text('编辑配置'),
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
            title: '任务',
            subtitle: '数据与操作均经 NAS 后端下发',
            child: !nasConfigured
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                    child: EmptyStateView(
                      icon: Icons.link_off,
                      title: '尚未配置 NAS 服务地址',
                      message: '任务列表由 NAS 后端从各下载器拉取，请先完成服务配对。',
                    ),
                  )
                : tasksAsync.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                      child: LoadingStateView(message: '正在读取任务'),
                    ),
                    error: (Object error, StackTrace stackTrace) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: ErrorStateView(
                        title: '任务获取失败',
                        message: error is ApiException ? error.message : '$error',
                        onRetry: () =>
                            ref.invalidate(downloaderTasksProvider(widget.downloaderId)),
                      ),
                    ),
                    data: (List<DownloaderTask> tasks) => tasks.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                            child: EmptyStateView(
                              icon: Icons.download_done_outlined,
                              title: '当前没有任务',
                              message: '从搜索结果推送下载后，任务会出现在这里。',
                            ),
                          )
                        : Column(
                            children: <Widget>[
                              for (final DownloaderTask task in tasks)
                                _TaskCard(
                                  task: task,
                                  busy: _busyHash == task.hash,
                                  onPause: () => _runAction(task, 'pause'),
                                  onResume: () => _runAction(task, 'resume'),
                                  onRemove: () => _removeTask(task),
                                ),
                            ],
                          ),
                  ),
          ),
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            onPressed: () => _confirmDeleteDownloader(config),
            icon: const Icon(Icons.delete_outline, size: AppSizes.iconSm),
            label: const Text('删除下载器'),
          ),
        ],
      ),
    );
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
          SizedBox(width: 84, child: Text(label, style: theme.textTheme.bodySmall)),
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

/// 单个任务卡片：进度、速率、剩余时间与操作菜单。
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.busy,
    required this.onPause,
    required this.onResume,
    required this.onRemove,
  });

  final DownloaderTask task;
  final bool busy;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRemove;

  static StatusTone _tone(TaskState state) => switch (state) {
        TaskState.downloading => StatusTone.info,
        TaskState.seeding => StatusTone.ok,
        TaskState.completed => StatusTone.ok,
        TaskState.paused => StatusTone.neutral,
        TaskState.queued => StatusTone.neutral,
        TaskState.checking => StatusTone.warning,
        TaskState.error => StatusTone.danger,
        TaskState.unknown => StatusTone.neutral,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  task.name.isEmpty ? '未命名任务' : task.name,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusBadge(label: task.state.label, tone: _tone(task.state), compact: true),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.chip),
            child: LinearProgressIndicator(value: task.progress, minHeight: 6),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${formatPercent(task.progress)} · ${formatBytes(task.completedBytes)} / ${formatBytes(task.sizeBytes)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.xxs),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xxs,
            children: <Widget>[
              Text('↓ ${formatSpeed(task.downloadSpeed)}', style: theme.textTheme.bodySmall),
              Text('↑ ${formatSpeed(task.uploadSpeed)}', style: theme.textTheme.bodySmall),
              Text('剩余 ${formatEta(task.etaSeconds)}', style: theme.textTheme.bodySmall),
              if (task.category.isNotEmpty)
                Text('分类 ${task.category}', style: theme.textTheme.bodySmall),
            ],
          ),
          if (task.savePath.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              task.savePath,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(AppSpacing.sm),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TextButton(
                        onPressed: task.state.isPaused ? onResume : onPause,
                        child: Text(task.state.isPaused ? '继续' : '暂停'),
                      ),
                      TextButton(
                        onPressed: onRemove,
                        child: const Text('移除'),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}