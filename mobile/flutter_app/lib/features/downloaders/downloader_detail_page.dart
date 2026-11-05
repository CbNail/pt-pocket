import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../shared/widgets/stat_grid.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/swipe_action_row.dart';
import 'downloader_providers.dart';
import 'widgets/add_task_sheet.dart';
import 'widgets/task_filter_sheet.dart';

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

  /// 当前左滑展开的任务（同一列表同时只允许一行展开）。
  String? _openTaskHash;

  /// 长按进入多选：与参考客户端一致，长按即选中该条并进入多选模式。
  void _enterSelection(String hash) {
    setState(() {
      _selectionMode = true;
      _selected
        ..clear()
        ..add(hash);
      _openTaskHash = null;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }
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

  // ---------- 任务操作菜单（右上角三个点 / 任务卡片右上角） ----------

  /// 当前操作目标：多选模式且有选中项时是选中的那些；否则为空（提示先长按选择）。
  List<DownloaderTask> _selectedTasks(List<DownloaderTask> all) {
    if (!_selectionMode || _selected.isEmpty) return const <DownloaderTask>[];
    return all
        .where((DownloaderTask task) => _selected.contains(task.hash))
        .toList(growable: false);
  }

  DownloaderKind get _kind =>
      ref.read(downloaderByIdProvider(widget.downloaderId))?.kind ?? DownloaderKind.qbittorrent;

  /// 任务操作菜单项：按引擎能力给出可用性；不可用项写明「该下载器不支持」。
  List<PopupMenuEntry<String>> _taskOpsItems(List<DownloaderTask> targets) {
    final DownloaderKind kind = _kind;
    final bool single = targets.length == 1;
    final DownloaderTask? one = single ? targets.first : null;
    final bool canCategory = kind == DownloaderKind.qbittorrent;
    final bool canAutoManaged = DownloaderGateway.supportsAutoManaged(kind);
    final bool forceOn =
        targets.isNotEmpty && targets.every((DownloaderTask task) => task.forceStart);
    final bool hasMagnet = one != null && one.magnetUri.isNotEmpty;

    return <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(value: 'location', child: Text('更改路径')),
      PopupMenuItem<String>(
        value: 'category',
        enabled: canCategory,
        child: Text(canCategory ? '更改分类' : '更改分类（该下载器不支持）'),
      ),
      const PopupMenuItem<String>(value: 'tags', child: Text('编辑标签')),
      const PopupMenuItem<String>(value: 'limits', child: Text('种子限速')),
      const PopupMenuDivider(),
      PopupMenuItem<String>(
        value: 'copyHash',
        enabled: single,
        child: Text(single ? '复制种子哈希' : '复制种子哈希（仅单个任务）'),
      ),
      PopupMenuItem<String>(
        value: 'copyMagnet',
        enabled: hasMagnet,
        child: Text(hasMagnet ? '复制磁力链接' : '复制磁力链接（无磁力链接）'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(value: 'reannounce', child: Text('重新汇报')),
      const PopupMenuItem<String>(value: 'recheck', child: Text('重新校验')),
      CheckedPopupMenuItem<String>(
        value: 'forceStart',
        checked: forceOn,
        child: const Text('强制继续'),
      ),
      PopupMenuItem<String>(
        value: 'autoManaged',
        enabled: canAutoManaged,
        child: Text(canAutoManaged ? '自动种子管理…' : '自动种子管理（该下载器不支持）'),
      ),
    ];
  }

  Future<void> _runTaskOp(String op, List<DownloaderTask> targets) async {
    if (targets.isEmpty) {
      _snack('先长按任务进入多选（或在任务卡片右上角点 ⋮）再操作');
      return;
    }
    final List<String> hashes =
        targets.map((DownloaderTask task) => task.hash).toList(growable: false);
    final DownloaderGateway api = ref.read(downloaderGatewayProvider);
    switch (op) {
      case 'location':
        await _changeLocation(hashes);
      case 'category':
        await _changeCategory(hashes);
      case 'tags':
        await _changeTags(hashes);
      case 'limits':
        await _changeLimits(hashes, targets);
      case 'copyHash':
        await _copy(targets.first.hash, '已复制种子哈希');
      case 'copyMagnet':
        await _copy(targets.first.magnetUri, '已复制磁力链接');
      case 'reannounce':
        await _simpleOp(() => api.reannounce(widget.downloaderId, hashes), '已下发重新汇报');
      case 'recheck':
        await _simpleOp(() => api.recheck(widget.downloaderId, hashes), '已下发重新校验');
      case 'forceStart':
        final bool next = !(targets.every((DownloaderTask task) => task.forceStart));
        await _simpleOp(
          () => api.setForceStart(widget.downloaderId, hashes, next),
          next ? '已开启强制继续' : '已关闭强制继续',
        );
      case 'autoManaged':
        await _changeAutoManaged(hashes);
    }
  }

  Future<void> _copy(String text, String message) async {
    if (text.isEmpty) {
      _snack('没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _snack(message);
  }

  Future<void> _simpleOp(Future<void> Function() action, String done) async {
    setState(() => _busyBatch = true);
    try {
      await action();
      _snack(done);
      _invalidateTasks();
    } on ApiException catch (error) {
      _snack('操作失败：${error.message}');
    } on DownloaderFetchException catch (error) {
      _snack('操作失败：${error.message}');
    } finally {
      if (mounted) setState(() => _busyBatch = false);
    }
  }

  /// 种子限速：输入单位用 KB/s（Transmission 的原生单位，避免换算误差）。
  Future<void> _changeLimits(List<String> hashes, List<DownloaderTask> targets) async {
    if (hashes.isEmpty) return;
    final DownloaderTask? one = targets.length == 1 ? targets.first : null;
    final _SeedLimits? limits = await showDialog<_SeedLimits>(
      context: context,
      builder: (BuildContext dialogContext) => _SeedLimitsDialog(
        downloadKb: one == null || one.downloadLimitBytes <= 0 ? 0 : one.downloadLimitBytes ~/ 1024,
        uploadKb: one == null || one.uploadLimitBytes <= 0 ? 0 : one.uploadLimitBytes ~/ 1024,
      ),
    );
    if (limits == null) return;

    final DownloaderGateway api = ref.read(downloaderGatewayProvider);
    await _simpleOp(
      () async {
        await api.setDownloadLimit(
          widget.downloaderId,
          hashes,
          limits.downloadKb <= 0 ? 0 : limits.downloadKb * 1024,
        );
        await api.setUploadLimit(
          widget.downloaderId,
          hashes,
          limits.uploadKb <= 0 ? 0 : limits.uploadKb * 1024,
        );
      },
      limits.downloadKb <= 0 && limits.uploadKb <= 0
          ? '已取消限速（不限）'
          : '已设置限速：下载 ${limits.downloadKb <= 0 ? '不限' : '${limits.downloadKb} KB/s'} · '
              '上传 ${limits.uploadKb <= 0 ? '不限' : '${limits.uploadKb} KB/s'}',
    );
  }

  /// 自动种子管理：只有 Transmission 有该开关；没有取值接口，用对话框确认。
  Future<void> _changeAutoManaged(List<String> hashes) async {
    if (hashes.isEmpty) return;
    bool enabled = true;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) => AlertDialog(
          title: const Text('自动种子管理'),
          content: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: (bool value) => setDialogState(() => enabled = value),
            title: const Text('开启自动管理'),
            subtitle: const Text('由下载器按队列与速率自动启停该任务'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await _simpleOp(
      () => ref.read(downloaderGatewayProvider).setAutoManaged(widget.downloaderId, hashes, enabled),
      enabled ? '已开启自动种子管理' : '已关闭自动种子管理',
    );
  }

  // ---------- 添加任务 ----------

  /// 打开「添加任务」面板：候选分类 / 标签 / 路径取不到也不影响（可手填）。
  Future<void> _openAddTaskSheet() async {
    final DownloaderConfig? config = ref.read(downloaderByIdProvider(widget.downloaderId));
    if (config == null) return;
    DownloaderTaskOption options = const DownloaderTaskOption();
    try {
      options = await ref.read(downloaderTaskOptionsProvider(widget.downloaderId).future);
    } catch (_) {
      // 候选值只是便利项；取不到就让用户手填，不阻断添加。
    }
    if (!mounted) return;
    final AddTaskRequest? request = await showAddTaskSheet(
      context,
      kind: config.kind,
      options: options,
      defaultSavePath: config.defaultSavePath,
    );
    if (request == null) return;
    await _submitAddTask(config, request);
  }

  Future<void> _submitAddTask(DownloaderConfig config, AddTaskRequest request) async {
    if (request.isEmpty) {
      _snack('请填种子链接，或选择一个种子文件');
      return;
    }
    final DownloaderGateway api = ref.read(downloaderGatewayProvider);
    setState(() => _busyBatch = true);
    try {
      if (request.links.isNotEmpty) {
        await api.addTorrentLinks(
          widget.downloaderId,
          links: request.links,
          category: request.category,
          tags: request.tags,
          savePath: request.savePath,
          paused: request.paused,
        );
      }
      if (request.hasFile) {
        await api.addTorrentFile(
          widget.downloaderId,
          bytes: request.fileBytes,
          filename: request.fileName,
          category: request.category,
          tags: request.tags,
          savePath: request.savePath,
          paused: request.paused,
        );
      }
      _snack('已向「${config.name}」提交 ${request.itemCount} 个任务');
      _invalidateTasks();
    } on ApiException catch (error) {
      _snack('添加失败：${error.message}');
    } on DownloaderFetchException catch (error) {
      _snack('添加失败：${error.message}');
    } finally {
      if (mounted) setState(() => _busyBatch = false);
    }
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
        leading: IconButton(
          icon: Icon(_selectionMode ? Icons.close : Icons.arrow_back),
          tooltip: _selectionMode ? '退出多选' : '返回',
          onPressed: _selectionMode ? _exitSelection : _leave,
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '筛选（状态 / 分类 / 标签 / 路径 / 服务器）与排序',
            onPressed: () => _openFilterSheet(
              tasksAsync.valueOrNull ?? const <DownloaderTask>[],
            ),
            icon: Badge(
              isLabelVisible: !_query.isEmptyFilter,
              label: Text('${_query.activeFilterCount}'),
              child: const Icon(Icons.filter_list),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '任务操作（路径 / 分类 / 标签 / 限速 / 复制 / 汇报 / 校验 / 强制继续）',
            icon: const Icon(Icons.more_vert),
            itemBuilder: (BuildContext context) =>
                _taskOpsItems(_selectedTasks(tasksAsync.valueOrNull ?? const <DownloaderTask>[])),
            onSelected: (String op) =>
                _runTaskOp(op, _selectedTasks(tasksAsync.valueOrNull ?? const <DownloaderTask>[])),
          ),
          IconButton(
            tooltip: '添加任务到该下载器',
            onPressed: _openAddTaskSheet,
            icon: const Icon(Icons.add),
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

    final QbTransferInfo? transfer = ref
        .watch(downloaderTransferProvider(widget.downloaderId))
        .valueOrNull;

    return Column(
      children: <Widget>[
        if (transfer != null) _transferBar(theme, transfer),
        _filterSummary(theme, tasks, visible.length, transfer?.version ?? ''),
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
                    final _TaskCard card = _TaskCard(
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
                      onLongPress: () => _enterSelection(task.hash),
                      menuItems: _selectionMode
                          ? const <PopupMenuEntry<String>>[]
                          : _taskOpsItems(<DownloaderTask>[task]),
                      onMenuSelected: (String op) => _runTaskOp(op, <DownloaderTask>[task]),
                    );

                    // 多选模式下不做左滑：否则「滑动选行」与「滑动露出操作」会互相打架。
                    if (_selectionMode) return card;
                    return SwipeActionRow(
                      itemKey: task.hash,
                      openKey: _openTaskHash,
                      onOpen: (String? key) => setState(() => _openTaskHash = key),
                      actions: <SwipeActionButton>[
                        SwipeActionButton(
                          label: task.isPaused ? '继续' : '暂停',
                          icon: task.isPaused ? Icons.play_arrow : Icons.pause,
                          onTap: () {
                            setState(() => _openTaskHash = null);
                            _taskAction(<String>[task.hash], task.isPaused ? 'resume' : 'pause');
                          },
                        ),
                        SwipeActionButton(
                          label: '删除',
                          icon: Icons.delete_outline,
                          background: theme.colorScheme.errorContainer,
                          foreground: theme.colorScheme.onErrorContainer,
                          onTap: () {
                            setState(() => _openTaskHash = null);
                            _removeTasks(<String>[task.hash]);
                          },
                        ),
                      ],
                      child: card,
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
          ],
      ),
    );
  }

  /// 打开筛选面板：状态 / 分类 / 标签 / 路径 / 服务器 + 排序，改动即时生效。
  Future<void> _openFilterSheet(List<DownloaderTask> tasks) async {
    if (tasks.isEmpty) {
      _snack('任务还没读取到，稍后再试或先刷新');
      return;
    }
    await showTaskFilterSheet(
      context,
      query: _query,
      tasks: tasks,
      onChanged: (TaskQuery next) => setState(() => _query = next),
    );
  }

  /// 筛选摘要 + 条数：条件写成一行，改条件点右上角三横线。
  Widget _filterSummary(
    ThemeData theme,
    List<DownloaderTask> tasks,
    int visibleCount,
    String version,
  ) {
    final List<String> parts = <String>[
      if (_query.statuses.isNotEmpty)
        '状态 ${_query.statuses.map((TaskState s) => s.label).join('/')}',
      if (_query.categories.isNotEmpty) '分类 ${_query.categories.join('/')}',
      if (_query.tags.isNotEmpty) '标签 ${_query.tags.join('/')}',
      if (_query.paths.isNotEmpty) '路径 ${_query.paths.join('/')}',
      if (_query.servers.isNotEmpty) '服务器 ${_query.servers.join('/')}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              _query.isEmptyFilter
                  ? '共 ${tasks.length} 条任务'
                  : '筛选出 $visibleCount 条 / 共 ${tasks.length} 条 · ${parts.join(' · ')}',
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (version.isNotEmpty) ...<Widget>[
            StatusBadge(label: 'v$version', tone: StatusTone.info, compact: true),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            '排序 ${_query.sort.label}${_query.descending ? ' ↓' : ' ↑'}',
            style: theme.textTheme.labelSmall,
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

/// 种子限速的结果（KB/s；0 表示不限）。
typedef _SeedLimits = ({int downloadKb, int uploadKb});

/// 种子限速对话框：由对话框自己持有输入控制器，避免「控制器已释放仍在渲染」。
class _SeedLimitsDialog extends StatefulWidget {
  const _SeedLimitsDialog({required this.downloadKb, required this.uploadKb});

  final int downloadKb;
  final int uploadKb;

  @override
  State<_SeedLimitsDialog> createState() => _SeedLimitsDialogState();
}

class _SeedLimitsDialogState extends State<_SeedLimitsDialog> {
  late final TextEditingController _download =
      TextEditingController(text: widget.downloadKb <= 0 ? '' : '${widget.downloadKb}');
  late final TextEditingController _upload =
      TextEditingController(text: widget.uploadKb <= 0 ? '' : '${widget.uploadKb}');

  @override
  void dispose() {
    _download.dispose();
    _upload.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('种子限速'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _download,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '下载限速（KB/s）',
              hintText: '0 或留空表示不限',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _upload,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '上传限速（KB/s）',
              hintText: '0 或留空表示不限',
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            downloadKb: int.tryParse(_download.text.trim()) ?? 0,
            uploadKb: int.tryParse(_upload.text.trim()) ?? 0,
          )),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

/// 单个任务卡片：进度、速率、剩余时间与操作。
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.busy,
    required this.selectionMode,
    required this.selected,
    required this.onSelected,
    required this.onLongPress,
    required this.menuItems,
    required this.onMenuSelected,
  });

  final DownloaderTask task;
  final bool busy;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onLongPress;

  /// 该任务的「三个点」操作项（多选模式下为空，批量操作走顶部菜单）。
  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onMenuSelected;

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
      // 长按进入多选；已进入多选时不再触发，避免误进。
      onLongPress: selectionMode ? null : onLongPress,
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  StatusBadge(label: task.state.label, tone: _tone(task.state), compact: true),
                  if (!selectionMode && menuItems.isNotEmpty)
                    PopupMenuButton<String>(
                      tooltip: '任务操作',
                      padding: EdgeInsets.zero,
                      iconSize: AppSizes.iconMd,
                      icon: const Icon(Icons.more_vert),
                      itemBuilder: (BuildContext context) => menuItems,
                      onSelected: onMenuSelected,
                    ),
                ],
              ),
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
          const SizedBox(height: AppSpacing.xs),
          // 指标统一走等宽统计网格：三列一行，行行铺满（不足一行时用等宽空位补齐）。
          StatGrid(
            columns: 3,
            items: <StatItem>[
              StatItem(
                label: '下载',
                value: formatSpeed(task.downloadSpeed),
                tone: AppColors.info,
              ),
              StatItem(
                label: '上传',
                value: formatSpeed(task.uploadSpeed),
                tone: AppColors.brand,
              ),
              StatItem(label: '剩余', value: formatEta(task.etaSeconds)),
              StatItem(
                label: '分享率',
                value: task.ratio > 0 ? task.ratio.toStringAsFixed(2) : '未提供',
                collected: task.ratio > 0,
              ),
              StatItem(
                label: '分类',
                value: task.category.isEmpty ? '未分类' : task.category,
                collected: task.category.isNotEmpty,
              ),
              StatItem(label: '服务器', value: task.serverLabel),
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
            ),
        ],
      ),
    );
  }
}