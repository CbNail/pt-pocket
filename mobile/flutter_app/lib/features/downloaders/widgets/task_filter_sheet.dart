import 'package:flutter/material.dart';

import '../../../core/models/downloader.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/equal_chip_grid.dart';

/// 任务筛选面板（右上角三横线打开）：**状态 / 分类 / 标签 / 路径 / 服务器** 五个维度 + 排序。
///
/// 口径：
/// - 每个维度第一枚胶囊是「全部×」，点它清空该维度；
/// - 状态、分类、路径、服务器按精确值匹配；标签是「带其中任意一个即命中」；
/// - 改动**即时生效**（回调把新条件交回页面），不需要额外的「应用」按钮；
/// - 只列出当前任务里真实存在的取值，不虚构候选值。
Future<void> showTaskFilterSheet(
  BuildContext context, {
  required TaskQuery query,
  required List<DownloaderTask> tasks,
  required ValueChanged<TaskQuery> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => _TaskFilterSheet(
      initial: query,
      tasks: tasks,
      onChanged: onChanged,
    ),
  );
}

class _TaskFilterSheet extends StatefulWidget {
  const _TaskFilterSheet({
    required this.initial,
    required this.tasks,
    required this.onChanged,
  });

  final TaskQuery initial;
  final List<DownloaderTask> tasks;
  final ValueChanged<TaskQuery> onChanged;

  @override
  State<_TaskFilterSheet> createState() => _TaskFilterSheetState();
}

class _TaskFilterSheetState extends State<_TaskFilterSheet> {
  late TaskQuery _query = widget.initial;

  void _update(TaskQuery next) {
    setState(() => _query = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // 每个维度的候选值只来自当前任务，按出现次数倒序（一眼看出分布）。
    final Map<String, int> categories = _valueCounts(
      widget.tasks.map((DownloaderTask t) => t.category).where((String v) => v.isNotEmpty),
    );
    final Map<String, int> paths = _valueCounts(
      widget.tasks.map((DownloaderTask t) => t.savePath).where((String v) => v.isNotEmpty),
    );
    final Map<String, int> servers = _valueCounts(
      widget.tasks.map((DownloaderTask t) => t.tracker).where((String v) => v.isNotEmpty),
    );
    final Map<String, int> tags = _valueCounts(
      widget.tasks.expand((DownloaderTask t) => t.tags).where((String v) => v.isNotEmpty),
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('筛选', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: _query.isEmptyFilter && _query.sort == TaskSort.addedAt
                      ? null
                      : () => _update(
                            _query.copyWith(
                              statuses: const <TaskState>{},
                              categories: const <String>{},
                              tags: const <String>{},
                              paths: const <String>{},
                              servers: const <String>{},
                              sort: TaskSort.addedAt,
                              descending: true,
                            ),
                          ),
                  child: const Text('重置'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // ---------- 状态 ----------
            _SectionTitle(title: '状态', count: widget.tasks.length, unit: '条任务'),
            const SizedBox(height: AppSpacing.xs),
            EqualChipGrid(
              children: <Widget>[
                FilterChip(
                  label: const Text('全部'),
                  selected: _query.statuses.isEmpty,
                  onSelected: (bool _) =>
                      _update(_query.copyWith(statuses: const <TaskState>{})),
                ),
                for (final TaskState state in TaskState.values)
                  FilterChip(
                    label: Text(
                      '${state.label} (${_countState(state)})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _query.statuses.contains(state),
                    onSelected: (bool value) {
                      final Set<TaskState> next = <TaskState>{..._query.statuses};
                      if (value) {
                        next.add(state);
                      } else {
                        next.remove(state);
                      }
                      _update(_query.copyWith(statuses: next));
                    },
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            _StringSection(
              title: '分类',
              emptyHint: '任务里还没有分类',
              allLabel: '全部分类',
              values: categories,
              selected: _query.categories,
              onChanged: (Set<String> next) => _update(_query.copyWith(categories: next)),
            ),
            const SizedBox(height: AppSpacing.md),
            _StringSection(
              title: '标签',
              emptyHint: '任务里还没有标签',
              allLabel: '全部标签',
              values: tags,
              selected: _query.tags,
              onChanged: (Set<String> next) => _update(_query.copyWith(tags: next)),
            ),
            const SizedBox(height: AppSpacing.md),
            _StringSection(
              title: '路径',
              emptyHint: '任务里还没有保存路径',
              allLabel: '全部路径',
              values: paths,
              selected: _query.paths,
              onChanged: (Set<String> next) => _update(_query.copyWith(paths: next)),
            ),
            const SizedBox(height: AppSpacing.md),
            _StringSection(
              title: '服务器',
              emptyHint: '任务里还没有服务器信息',
              allLabel: '全部服务器',
              values: servers,
              selected: _query.servers,
              onChanged: (Set<String> next) => _update(_query.copyWith(servers: next)),
            ),
            const SizedBox(height: AppSpacing.md),

            // ---------- 排序 ----------
            _SectionTitle(title: '排序'),
            const SizedBox(height: AppSpacing.xs),
            EqualChipGrid(
              children: <Widget>[
                for (final TaskSort sort in TaskSort.values)
                  ChoiceChip(
                    label: Text(
                      sort.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _query.sort == sort,
                    onSelected: (bool _) => _update(_query.copyWith(sort: sort)),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _query.descending,
              onChanged: (bool value) => _update(_query.copyWith(descending: value)),
              title: const Text('倒序（新加入 / 大在前）'),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  int _countState(TaskState state) =>
      widget.tasks.where((DownloaderTask task) => task.state == state).length;

  static Map<String, int> _valueCounts(Iterable<String> values) {
    final Map<String, int> counts = <String, int>{};
    for (final String value in values) {
      counts[value] = (counts[value] ?? 0) + 1;
    }
    final List<MapEntry<String, int>> entries = counts.entries.toList();
    entries.sort((MapEntry<String, int> a, MapEntry<String, int> b) {
      final int byValue = b.value.compareTo(a.value);
      return byValue != 0 ? byValue : a.key.compareTo(b.key);
    });
    return Map<String, int>.fromEntries(entries);
  }
}

/// 一个字符串维度的筛选段（分类 / 标签 / 路径 / 服务器共用）。
class _StringSection extends StatelessWidget {
  const _StringSection({
    required this.title,
    required this.emptyHint,
    required this.allLabel,
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  final String title;
  final String emptyHint;
  final String allLabel;
  final Map<String, int> values;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (values.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SectionTitle(title: title),
          const SizedBox(height: AppSpacing.xxs),
          Text(emptyHint, style: theme.textTheme.bodySmall),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionTitle(title: title, count: values.length, unit: '项'),
        const SizedBox(height: AppSpacing.xs),
        EqualChipGrid(
          children: <Widget>[
            FilterChip(
              label: Text(allLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: selected.isEmpty,
              onSelected: (bool _) => onChanged(<String>{}),
            ),
            for (final MapEntry<String, int> entry in values.entries)
              FilterChip(
                label: Text(
                  '${entry.key} (${entry.value})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: selected.contains(entry.key),
                onSelected: (bool value) {
                  final Set<String> next = <String>{...selected};
                  if (value) {
                    next.add(entry.key);
                  } else {
                    next.remove(entry.key);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.count, this.unit});

  final String title;
  final int? count;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(title, style: theme.textTheme.titleSmall),
        if (count != null) ...<Widget>[
          const SizedBox(width: AppSpacing.xs),
          Text('$count${unit ?? ''}', style: theme.textTheme.labelSmall),
        ],
      ],
    );
  }
}