import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/downloader.dart';
import '../../../core/services/platform_file_picker.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/equal_chip_grid.dart';

/// 添加任务面板（任务页右上角「＋」打开）。
///
/// 字段与参考实现对齐：**种子链接（可多行）、种子文件、自动种子管理、
/// 添加分类、添加标签、保存路径、添加后暂停**。
///
/// 口径：
/// - 「自动种子管理」只有 Transmission 支持（qBittorrent 用队列与优先级管理），
///   不支持时开关禁用并写明原因；
/// - 开启自动种子管理后，分类 / 标签 / 保存路径交给下载器自动决定，手动项随之禁用
///   （与参考实现一致：手动设定需关闭自动种子管理）；
/// - 分类同样只有 qBittorrent 有，Transmission 时该分区写明原因。
Future<AddTaskRequest?> showAddTaskSheet(
  BuildContext context, {
  required DownloaderKind kind,
  required DownloaderTaskOption options,
  String defaultSavePath = '',
}) {
  return showModalBottomSheet<AddTaskRequest>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => _AddTaskSheet(
      kind: kind,
      options: options,
      defaultSavePath: defaultSavePath,
    ),
  );
}

class _AddTaskSheet extends StatefulWidget {
  const _AddTaskSheet({
    required this.kind,
    required this.options,
    required this.defaultSavePath,
  });

  final DownloaderKind kind;
  final DownloaderTaskOption options;
  final String defaultSavePath;

  @override
  State<_AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<_AddTaskSheet> {
  final TextEditingController _links = TextEditingController();
  late final TextEditingController _savePath =
      TextEditingController(text: widget.defaultSavePath);
  final TextEditingController _newTag = TextEditingController();

  final Set<String> _tags = <String>{};
  String _category = '';

  /// 自动种子管理：Transmission 默认开启，qBittorrent 不支持（开关禁用）。
  late bool _autoManaged = _autoManagedSupported;

  bool _paused = false;
  String _fileName = '';
  List<int> _fileBytes = const <int>[];

  bool get _autoManagedSupported => widget.kind == DownloaderKind.transmission;
  bool get _categorySupported => widget.kind == DownloaderKind.qbittorrent;

  /// 手动项是否可用：开启自动种子管理后交给下载器决定。
  bool get _manualEnabled => !(_autoManagedSupported && _autoManaged);

  @override
  void dispose() {
    _links.dispose();
    _savePath.dispose();
    _newTag.dispose();
    super.dispose();
  }

  List<String> get _validLinks => _links.text
      .split(RegExp(r'[\r\n]+'))
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList(growable: false);

  Future<void> _pickFile() async {
    try {
      final PickedFileData? picked = await const PlatformFilePicker().pick(
        mimeTypes: const <String>['application/x-bittorrent', 'application/octet-stream', '*/*'],
      );
      if (picked == null || !mounted) return;
      setState(() {
        _fileName = picked.name;
        _fileBytes = picked.bytes.toList(growable: false);
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      _snack('无法打开文件选择器：${error.message ?? error.code}（可改用种子链接）');
    } on MissingPluginException {
      if (!mounted) return;
      _snack('当前平台没有文件选择器，请改用种子链接');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _submit() {
    final List<String> links = _validLinks;
    final bool hasFile = _fileName.isNotEmpty && _fileBytes.isNotEmpty;
    if (links.isEmpty && !hasFile) {
      _snack('请填种子链接，或选择一个种子文件');
      return;
    }
    final Set<String> tags = <String>{
      ..._tags,
      ..._newTag.text
          .split(',')
          .map((String item) => item.trim())
          .where((String item) => item.isNotEmpty),
    };
    Navigator.of(context).pop(AddTaskRequest(
      links: links,
      fileName: _fileName,
      fileBytes: _fileBytes,
      autoManaged: _autoManagedSupported && _autoManaged,
      category: _manualEnabled && _categorySupported ? _category : '',
      tags: _manualEnabled ? tags.toList(growable: false) : const <String>[],
      savePath: _manualEnabled ? _savePath.text.trim() : '',
      paused: _paused,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('添加任务 · ${widget.kind.label}', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),

            // ---------- 种子链接 / 种子文件 ----------
            TextField(
              controller: _links,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '种子链接',
                hintText: '添加多个时请换行',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _fileName.isEmpty ? '种子文件：点击右侧按钮添加' : '种子文件：$_fileName',
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '选择种子文件',
                  onPressed: _pickFile,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const Divider(height: AppSpacing.lg),

            // ---------- 自动种子管理 ----------
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _autoManaged,
              onChanged: _autoManagedSupported
                  ? (bool value) => setState(() => _autoManaged = value)
                  : null,
              title: const Text('自动种子管理'),
              subtitle: Text(
                _autoManagedSupported
                    ? '由下载器按队列与速率自动启停新增任务'
                    : '该下载器不支持（qBittorrent 用队列与优先级管理）',
                style: theme.textTheme.bodySmall,
              ),
            ),

            // ---------- 添加分类 ----------
            _SectionTitle(title: '添加分类'),
            const SizedBox(height: AppSpacing.xs),
            if (!_categorySupported)
              Text('该下载器不支持分类（Transmission 只有标签）', style: theme.textTheme.bodySmall)
            else if (!_manualEnabled)
              Text('手动设定需关闭自动种子管理', style: theme.textTheme.bodySmall)
            else
              EqualChipGrid(
                children: <Widget>[
                  ChoiceChip(
                    label: const Text('不设置', maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: _category.isEmpty,
                    onSelected: (bool _) => setState(() => _category = ''),
                  ),
                  for (final String category in widget.options.categories)
                    ChoiceChip(
                      label: Text(category, maxLines: 1, overflow: TextOverflow.ellipsis),
                      selected: _category == category,
                      onSelected: (bool _) => setState(() => _category = category),
                    ),
                ],
              ),
            const SizedBox(height: AppSpacing.md),

            // ---------- 添加标签 ----------
            _SectionTitle(title: '添加标签'),
            const SizedBox(height: AppSpacing.xs),
            if (!_manualEnabled)
              Text('手动设定需关闭自动种子管理', style: theme.textTheme.bodySmall)
            else ...<Widget>[
              EqualChipGrid(
                children: <Widget>[
                  for (final String tag in widget.options.tags)
                    FilterChip(
                      label: Text(tag, maxLines: 1, overflow: TextOverflow.ellipsis),
                      selected: _tags.contains(tag),
                      onSelected: (bool value) => setState(() {
                        if (value) {
                          _tags.add(tag);
                        } else {
                          _tags.remove(tag);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                controller: _newTag,
                decoration: const InputDecoration(
                  labelText: '新标签',
                  hintText: '多个标签用逗号分隔',
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),

            // ---------- 保存路径 ----------
            _SectionTitle(
              title: '保存路径',
              trailing: _manualEnabled ? null : '手动设定需关闭自动种子管理',
            ),
            const SizedBox(height: AppSpacing.xs),
            TextField(
              controller: _savePath,
              enabled: _manualEnabled,
              decoration: InputDecoration(
                hintText: widget.defaultSavePath.isEmpty ? '/downloads/PT' : widget.defaultSavePath,
              ),
            ),
            if (_manualEnabled && widget.options.paths.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              EqualChipGrid(
                children: <Widget>[
                  for (final String path in widget.options.paths)
                    ActionChip(
                      label: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onPressed: () => setState(() => _savePath.text = path),
                    ),
                ],
              ),
            ],
            const Divider(height: AppSpacing.lg),

            // ---------- 添加后暂停 ----------
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _paused,
              onChanged: (bool value) => setState(() => _paused = value),
              title: const Text('添加后暂停'),
            ),
            const SizedBox(height: AppSpacing.md),
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
                  child: FilledButton(onPressed: _submit, child: const Text('添加')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Text(title, style: theme.textTheme.titleSmall),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              trailing!,
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ],
    );
  }
}