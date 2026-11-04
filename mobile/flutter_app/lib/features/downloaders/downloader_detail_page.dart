import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/direct/downloader_gateway.dart';
import '../../core/direct/qbittorrent_client.dart';
import '../../core/models/downloader.dart';
import '../../core/network/api_exception.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import 'downloader_providers.dart';

/// 下载器任务中心（需求 3）。
///
/// 设计口径：连接信息与「测试连接 / 编辑配置」等操作框只在外层列表呈现
/// ——外层那个状态圆点已经表达「连接是否正常」，进来后重复展示只是噪音。
/// 本页只做任务本身：筛选、排序、批量操作与单条任务操作。
///
/// 任务数据与操作走 [DownloaderGateway]：qBittorrent 直接调用 WebUI（`/api/v2`）
/// 取任务与下发操作（参考 PT-depiler「我的下载器」与 Bit Control 之类的客户端），
/// 其余引擎或本地取不到时回退 NAS 后端接口。
class DownloaderDetailPage extends ConsumerStatefulWidget {
  const DownloaderDetailPage({super.key, required this.downloaderId});

  final String downloaderId;

  @override
  ConsumerState<DownloaderDetailPage> createState() => _DownloaderDetailPageState();
}

class _DownloaderDetailPageState extends ConsumerState<DownloaderDetailPage> {
  TaskQuery _query = const TaskQuery();
  final Set<String> _selected = <String>{};
  bool _selectionMode = false;
  String? _busyHash;
  bool _busyBatch = false;

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

  void _invalidateTasks() => ref.invalidate(downloaderTasksProvider(widget.downloaderId));

  List<String> get _targetHashes => _selected.isEmpty
      ? const <String>[]
      : _selected.toList(growable: false);

  // ---------- 单条任务操作 ----------

  Future<void> _taskAction(List<String> hashes, String action) async {
    if (hashes.isEmpty) return;
    final DownloaderGateway api = ref.read(downloaderGatewayProvider);
    if (hashes.length == 1) setState(() => _busyHash = hashes.first);
    setState(() => _busyBatch = hashes.length > 1);
    try {
      switch (action) {
        case 'pause':
          await api.pause(widget.downloaderId, hashes);
        case 'resume':
          await api.resume(widget.downloaderId, hashes);
      }
      _snack(hashes.length == 1 ? '已下发${action == 'pause' ? '暂停' : '继续'}' : '已批量下发 ${hashes.length} 条');
      _invalidateTasks();
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    } on DownloaderFetchException catch (error) {
      _snack('操作失败：${error.message}');
    } finally {
      if (mounted) {
        setState(() {
          _busyHash = null;
          _busyBatch = false;
        });
      }
    }
  }

  Future<void> _removeTasks(List<String> hashes) async {
    if (hashes.isEmpty) return;
    final bool? deleteFiles = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(hashes.length == 1 ? '移除任务' : '批量移除任务'),
        content: Text(
          hashes.length == 1
              ? '「${_nameOf(hashes.first)}」：只移除任务记录，还是同时删除已下载的数据？'
              : '共 ${hashes.length} 条任务：只移除任务记录，还是同时删除已下载的数据？',
        ),
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

    setState(() => _busyBatch = hashes.length > 1);
    try {
      await ref
          .read(downloaderGatewayProvider)
          .remove(widget.downloaderId, hashes, deleteFiles: deleteFiles);
      _snack(deleteFiles ? '已下发删除任务与文件' : '已下发移除任务');
      setState(() => _selected.clear());
      _invalidateTasks();
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    } on DownloaderFetchException catch (error) {
      _snack('操作失败：${error.message}');
    } finally {
      if (mounted) setState(() => _busyBatch = false);
    }
  }

  String _nameOf(String hash) {
    final List<DownloaderTask> tasks =
        ref.read(downloaderTasksProvider(widget.downloaderId)).valueOrNull ??
            const <DownloaderTask>[];
    for (final DownloaderTask task in tasks) {
      if (task.hash == hash) return task.name.isEmpty ? '未命名任务' : task.name;
    }
    return hash;
  }

  // ---------- 分类 / 标签 / 路径 ----------

  Future<void> _changeCategory(List<String> hashes) async {
    if (hashes.isEmpty) return;
    final DownloaderTaskOption options =
        await ref.read(downloaderTaskOptionsProvider(widget.downloaderId).future);
    if (!mounted) return;
    final String? category = await _showTextChoiceDialog(
      title: '更改分类',
      hint: '留空表示清除分类',
      choices: options.categories,
      allowClear: true,
    );
    if (category == null) return;
    try {
      await ref.read(downloaderGatewayProvider).setCategory(widget.downloaderId, hashes, category);
      _snack(category.isEmpty ? '已清除分类' : '已改为分类「$category」');
      _invalidateTasks();
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    }
  }

  Future<void> _changeTags(List<String> hashes) async {
    if (hashes.isEmpty) return;
    final DownloaderTaskOption options =
        await ref.read(downloaderTaskOptionsProvider(widget.downloaderId).future);
    if (!mounted) return;
    final _TagsResult? result = await _showTagsDialog(options.tags);
    if (result == null) return;
    try {
      await ref.read(downloaderGatewayProvider).setTags(
            widget.downloaderId,
            hashes,
            result.tags,
            mode: result.mode,
          );
      _snack('已${result.modeLabel}标签（${result.tags.length} 个）');
      _invalidateTasks();
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    }
  }

  Future<void> _changeLocation(List<String> hashes) async {
    if (hashes.isEmpty) return;
    final DownloaderTaskOption options =
        await ref.read(downloaderTaskOptionsProvider(widget.downloaderId).future);
    if (!mounted) return;
    final String? path = await _showTextChoiceDialog(
      title: '更改保存路径',
      hint: '例如 /downloads/PT',
      choices: options.paths,
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      await ref.read(downloaderGatewayProvider).setLocation(widget.downloaderId, hashes, path.trim());
      _snack('已改保存路径为 ${path.trim()}');
      _invalidateTasks();
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    }
  }

  /// 分类 / 路径共用的「从已知候选中挑一个，或自己填」对话框。
  Future<String?> _showTextChoiceDialog({
    required String title,
    required String hint,
    required List<String> choices,
    bool allowClear = false,
  }) {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (choices.isNotEmpty) ...<Widget>[
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xxs,
                    children: <Widget>[
                      for (final String choice in choices)
                        ActionChip(
                          label: Text(choice),
                          onPressed: () => setDialogState(() => controller.text = choice),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: Text(
                      '后端暂未提供候选，可直接填写',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(labelText: '填写值', hintText: hint),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('取消'),
            ),
            if (allowClear)
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(''),
                child: const Text('清除'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Future<_TagsResult?> _showTagsDialog(List<String> known) {
    final Set<String> picked = <String>{};
    final TextEditingController controller = TextEditingController();
    String mode = 'add';

    return showDialog<_TagsResult>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) => AlertDialog(
          title: const Text('设置标签'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SegmentedButton<String>(
                  segments: const <ButtonSegment<String>>[
                    ButtonSegment<String>(value: 'add', label: Text('追加')),
                    ButtonSegment<String>(value: 'set', label: Text('覆盖')),
                    ButtonSegment<String>(value: 'remove', label: Text('移除')),
                  ],
                  selected: <String>{mode},
                  onSelectionChanged: (Set<String> value) =>
                      setDialogState(() => mode = value.first),
                ),
                const SizedBox(height: AppSpacing.md),
                Text('已有标签', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xxs,
                  children: <Widget>[
                    for (final String tag in known)
                      FilterChip(
                        label: Text(tag),
                        selected: picked.contains(tag),
                        onSelected: (bool value) => setDialogState(() {
                          if (value) {
                            picked.add(tag);
                          } else {
                            picked.remove(tag);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: '新标签',
                    hintText: '多个标签用逗号分隔',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final Set<String> tags = <String>{
                  ...picked,
                  ...controller.text
                      .split(',')
                      .map((String item) => item.trim())
                      .where((String item) => item.isNotEmpty),
                };
                if (tags.isEmpty) {
                  Navigator.of(dialogContext).pop();
                  return;
                }
                Navigator.of(dialogContext).pop(
                  _TagsResult(
                    tags: tags.toList(growable: false),
                    mode: mode,
                  ),
                );
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DownloaderConfig? config = ref.watch(downloaderByIdProvider(widget.downloaderId));

    if (config == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('任务'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        ),
        body: ErrorStateView(
          title: '下载器不存在',
          message: '该下载器可能已被删除，返回列表重新选择。',
          onRetry: _leave,
        ),
      );
    }

    final AsyncValue<List<DownloaderTask>> tasksAsync =
        ref.watch(downloaderTasksProvider(widget.downloaderId));

    return Scaffold(
      appBar: AppBar(
        title: Text(config.name),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        actions: <Widget>[
          IconButton(
            tooltip: _selectionMode ? '退出多选' : '多选任务',
            onPressed: () => setState(() {
              _selectionMode = !_selectionMode;
              if (!_selectionMode) _selected.clear();
            }),
            icon: Icon(_selectionMode ? Icons.close : Icons.checklist),
          ),
          PopupMenuButton<TaskSort>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            onSelected: (TaskSort sort) => setState(() => _query = _query.copyWith(sort: sort)),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<TaskSort>>[
              for (final TaskSort sort in TaskSort.values)
                CheckedPopupMenuItem<TaskSort>(
                  value: sort,
                  checked: _query.sort == sort,
                  child: Text(sort.label),
                ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem<TaskSort>(
                value: _query.sort,
                checked: _query.descending,
                child: const Text('倒序（新/大在前）'),
              ),
            ],
          ),
          IconButton(
            tooltip: '刷新任务',
            onPressed: _invalidateTasks,
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: tasksAsync.when(
        loading: () => const LoadingStateView(message: '正在读取任务'),
        error: (Object error, StackTrace stackTrace) => ErrorStateView(
          title: '任务获取失败',
          // 直接把失败原因（凭据 / 白名单 / 网络）显示出来，便于就地修正。
          message: switch (error) {
            ApiException e => e.message,
            DownloaderFetchException e => '${e.kind.label}：${e.message}',
            _ => '$error',
          },
          onRetry: _invalidateTasks,
        ),
        data: (List<DownloaderTask> tasks) => _tasksView(theme, tasks),
      ),
      bottomNavigationBar: _selectionMode ? _batchBar(theme, tasksAsync.valueOrNull) : null,
    );
  }

  Widget _tasksView(ThemeData theme, List<DownloaderTask> tasks) {
    final List<DownloaderTask> visible = _query.apply(tasks);
    final List<String> servers = <String>{
      for (final DownloaderTask task in tasks) if (task.tracker.isNotEmpty) task.tracker,
    }.toList(growable: false)
      ..sort();

    final QbTransferInfo? transfer = ref
        .watch(downloaderTransferProvider(widget.downloaderId))
        .valueOrNull;

    return Column(
      children: <Widget>[
        if (transfer != null) _transferBar(theme, transfer),
        _filterBar(theme, servers, tasks),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _query.isEmptyFilter
                  ? '共 ${tasks.length} 条任务'
                  : '筛选出 ${visible.length} 条 / 共 ${tasks.length} 条',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? EmptyStateView(
                  icon: Icons.download_done_outlined,
                  title: tasks.isEmpty ? '当前没有任务' : '没有符合筛选条件的任务',
                  message: tasks.isEmpty
                      ? '从搜索结果推送下载后，任务会出现在这里。'
                      : '换一个状态或服务器筛选看看。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.xs,
                    AppSpacing.lg,
                    AppSpacing.xxl,
                  ),
                  itemCount: visible.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const SizedBox(height: AppSpacing.md),
                  itemBuilder: (BuildContext context, int index) {
                    final DownloaderTask task = visible[index];
                    return _TaskCard(
                      task: task,
                      busy: _busyHash == task.hash || _busyBatch,
                      selectionMode: _selectionMode,
                      selected: _selected.contains(task.hash),
                      onSelected: (bool value) => setState(() {
                        if (value) {
                          _selected.add(task.hash);
                        } else {
                          _selected.remove(task.hash);
                        }
                      }),
                      onPause: () => _taskAction(<String>[task.hash], 'pause'),
                      onResume: () => _taskAction(<String>[task.hash], 'resume'),
                      onRemove: () => _removeTasks(<String>[task.hash]),
                      onCategory: () => _changeCategory(<String>[task.hash]),
                      onTags: () => _changeTags(<String>[task.hash]),
                      onLocation: () => _changeLocation(<String>[task.hash]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 全局传输状态条（速度 / 累计流量 / 版本），qBittorrent 直连时可见。
  Widget _transferBar(ThemeData theme, QbTransferInfo info) {
    final List<(String, String)> items = <(String, String)>[
      ('下载速度', formatSpeed(info.downloadSpeed)),
      ('上传速度', formatSpeed(info.uploadSpeed)),
      ('本次下载', formatBytes(info.downloadedBytes)),
      ('本次上传', formatBytes(info.uploadedBytes)),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.cardBorder,
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < items.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(items[i].$1, style: theme.textTheme.labelSmall),
                  Text(
                    items[i].$2,
                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
          if (info.version.isNotEmpty)
            StatusBadge(label: 'qB ${info.version}', tone: StatusTone.info, compact: true),
        ],
      ),
    );
  }

  Widget _filterBar(ThemeData theme, List<String> servers, List<DownloaderTask> tasks) {
    int countOf(TaskState state) =>
        tasks.where((DownloaderTask task) => task.state == state).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xxs,
            children: <Widget>[
              FilterChip(
                label: const Text('全部状态'),
                selected: _query.statuses.isEmpty,
                onSelected: (bool _) =>
                    setState(() => _query = _query.copyWith(statuses: <TaskState>{})),
              ),
              for (final TaskState state in const <TaskState>[
                TaskState.downloading,
                TaskState.seeding,
                TaskState.completed,
                TaskState.paused,
                TaskState.queued,
                TaskState.checking,
                TaskState.error,
              ])
                FilterChip(
                  // 带上各状态数量（和 Bit Control 之类的客户端一样一眼看出分布），
                  // 数量单独放一个 Text，状态名仍是独立文本节点，便于读屏与按文本查找。
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(state.label),
                      const SizedBox(width: AppSpacing.xxs),
                      Text('${countOf(state)}', style: theme.textTheme.labelSmall),
                    ],
                  ),
                  selected: _query.statuses.contains(state),
                  onSelected: (bool value) => setState(() {
                    final Set<TaskState> next = <TaskState>{..._query.statuses};
                    if (value) {
                      next.add(state);
                    } else {
                      next.remove(state);
                    }
                    _query = _query.copyWith(statuses: next);
                  }),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: <Widget>[
              Text('服务器', style: theme.textTheme.bodySmall),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _query.tracker.isEmpty ? '' : _query.tracker,
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(value: '', child: Text('全部服务器')),
                    for (final String server in servers)
                      DropdownMenuItem<String>(value: server, child: Text(server)),
                  ],
                  onChanged: (String? value) =>
                      setState(() => _query = _query.copyWith(tracker: value ?? '')),
                ),
              ),
              TextButton(
                onPressed: _query.isEmptyFilter && _query.sort == TaskSort.addedAt
                    ? null
                    : () => setState(() => _query = const TaskQuery()),
                child: const Text('重置'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 多选模式下的批量操作条。
  Widget _batchBar(ThemeData theme, List<DownloaderTask>? allTasks) {
    final List<DownloaderTask> tasks = allTasks ?? const <DownloaderTask>[];
    final bool allSelected = tasks.isNotEmpty && _selected.length == tasks.length;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          border: Border(top: BorderSide(color: theme.colorScheme.outline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('已选 ${_selected.length} 条', style: theme.textTheme.labelLarge),
                const Spacer(),
                TextButton(
                  onPressed: tasks.isEmpty
                      ? null
                      : () => setState(() {
                            if (allSelected) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(tasks.map((DownloaderTask t) => t.hash));
                            }
                          }),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  TextButton.icon(
                    onPressed: _targetHashes.isEmpty ? null : () => _taskAction(_targetHashes, 'pause'),
                    icon: const Icon(Icons.pause, size: AppSizes.iconSm),
                    label: const Text('暂停'),
                  ),
                  TextButton.icon(
                    onPressed: _targetHashes.isEmpty ? null : () => _taskAction(_targetHashes, 'resume'),
                    icon: const Icon(Icons.play_arrow, size: AppSizes.iconSm),
                    label: const Text('继续'),
                  ),
                  TextButton.icon(
                    onPressed: _targetHashes.isEmpty ? null : () => _changeCategory(_targetHashes),
                    icon: const Icon(Icons.folder_outlined, size: AppSizes.iconSm),
                    label: const Text('分类'),
                  ),
                  TextButton.icon(
                    onPressed: _targetHashes.isEmpty ? null : () => _changeTags(_targetHashes),
                    icon: const Icon(Icons.local_offer_outlined, size: AppSizes.iconSm),
                    label: const Text('标签'),
                  ),
                  TextButton.icon(
                    onPressed: _targetHashes.isEmpty ? null : () => _changeLocation(_targetHashes),
                    icon: const Icon(Icons.drive_file_move_outline, size: AppSizes.iconSm),
                    label: const Text('路径'),
                  ),
                  TextButton.icon(
                    onPressed: _targetHashes.isEmpty ? null : () => _removeTasks(_targetHashes),
                    icon: const Icon(Icons.delete_outline, size: AppSizes.iconSm),
                    label: const Text('删除'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标签设置对话框的结果。
class _TagsResult {
  const _TagsResult({required this.tags, required this.mode});

  final List<String> tags;

  /// `add` / `set` / `remove`。
  final String mode;

  String get modeLabel => switch (mode) {
        'set' => '覆盖为',
        'remove' => '移除',
        _ => '追加',
      };
}

/// 单个任务卡片：进度、速率、剩余时间与操作。
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.busy,
    required this.selectionMode,
    required this.selected,
    required this.onSelected,
    required this.onPause,
    required this.onResume,
    required this.onRemove,
    required this.onCategory,
    required this.onTags,
    required this.onLocation,
  });

  final DownloaderTask task;
  final bool busy;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRemove;
  final VoidCallback onCategory;
  final VoidCallback onTags;
  final VoidCallback onLocation;

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
    return SectionCard(
      onTap: selectionMode ? () => onSelected(!selected) : null,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (selectionMode) ...<Widget>[
                Checkbox(value: selected, onChanged: (bool? value) => onSelected(value ?? false)),
                const SizedBox(width: AppSpacing.xs),
              ],
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
              if (task.ratio > 0)
                Text('分享率 ${task.ratio.toStringAsFixed(2)}', style: theme.textTheme.bodySmall),
              if (task.category.isNotEmpty)
                Text('分类 ${task.category}', style: theme.textTheme.bodySmall),
              Text('服务器 ${task.serverLabel}', style: theme.textTheme.bodySmall),
            ],
          ),
          if (task.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xxs,
              children: <Widget>[
                for (final String tag in task.tags)
                  StatusBadge(label: tag, tone: StatusTone.info, compact: true),
              ],
            ),
          ],
          if (task.savePath.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xxs),
            Text(
              task.savePath,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (busy)
            const Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.sm),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else if (!selectionMode)
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: AppSpacing.xs,
                children: <Widget>[
                  TextButton(
                    onPressed: task.isPaused ? onResume : onPause,
                    child: Text(task.isPaused ? '继续' : '暂停'),
                  ),
                  TextButton(onPressed: onCategory, child: const Text('分类')),
                  TextButton(onPressed: onTags, child: const Text('标签')),
                  TextButton(onPressed: onLocation, child: const Text('路径')),
                  TextButton(onPressed: onRemove, child: const Text('移除')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}