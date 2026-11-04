import 'dart:io' show File;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/pt_site.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/ptd_backup_importer.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import 'site_providers.dart';

/// PTD / PT-depiler 备份导入（需求 1）。
///
/// 备份结构随版本演进，解析采用字段别名宽松匹配：无法识别的条目会被跳过并提示，
/// 不做静默丢弃。
class PtdImportPage extends ConsumerStatefulWidget {
  const PtdImportPage({super.key});

  @override
  ConsumerState<PtdImportPage> createState() => _PtdImportPageState();
}

class _PtdImportPageState extends ConsumerState<PtdImportPage> {
  final TextEditingController _text = TextEditingController();
  PtdImportResult? _result;
  bool _importing = false;
  int? _importedCount;

  /// 已选中的备份文件名（zip 或 json）。
  String? _fileName;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.sites);
    }
  }

  void _parse() {
    setState(() {
      _result = ref.read(ptdImporterProvider).parse(_text.text);
      _importedCount = null;
      _fileName = null;
      _error = null;
    });
  }

  /// 选择 PTD 插件导出的备份文件（zip 优先，也兼容单个 json）。
  ///
  /// App 自行识别 zip 内的成员，不需要用户手动指定该用哪个文件。
  Future<void> _pickFile() async {
    try {
      final FilePickerResult? picked = await FilePicker.pickFiles(
        dialogTitle: '选择 PTD 备份',
        type: FileType.custom,
        allowedExtensions: <String>['zip', 'json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final PlatformFile file = picked.files.first;
      Uint8List? bytes = file.bytes;
      final String? path = file.path;
      if (bytes == null && path != null) {
        bytes = await File(path).readAsBytes();
      }
      if (bytes == null) {
        if (!mounted) return;
        setState(() => _error = '读取不到所选文件的内容，请换一个文件重试');
        return;
      }

      final PtdImportResult result = ref.read(ptdImporterProvider).parseBytes(bytes);
      if (!mounted) return;
      setState(() {
        _result = result;
        _fileName = file.name;
        _importedCount = null;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '选择文件失败：$error');
    }
  }

  Future<void> _importAll() async {
    final PtdImportResult? result = _result;
    if (result == null) return;

    final List<PtSite> existing = ref.read(siteListProvider).valueOrNull ?? const <PtSite>[];
    final Set<String> existingHosts = existing.map((PtSite s) => s.host.toLowerCase()).toSet();
    final SiteListNotifier notifier = ref.read(siteListProvider.notifier);
    int imported = 0;

    setState(() => _importing = true);
    for (final PtdImportEntry entry in result.importableEntries) {
      final Uri? uri = SiteReachabilityProbe.parseSiteUri(entry.baseUrl!);
      if (uri == null) continue;
      final String host = uri.host.toLowerCase();
      if (existingHosts.contains(host)) continue;

      final String id = const Uuid().v4();
      final SiteAuthType authType = entry.cookieString != null
          ? SiteAuthType.cookie
          : (entry.apiKey != null ? SiteAuthType.apiKey : SiteAuthType.passkey);
      final Map<String, dynamic>? credential = _credentialFor(entry);
      await notifier.upsert(
        PtSite(
          id: id,
          name: entry.name,
          baseUrl: uri.toString(),
          authType: authType,
          credentialConfigured: credential != null,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      if (credential != null) {
        await notifier.saveCredential(id, credential);
      }
      existingHosts.add(host);
      imported++;
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _importedCount = imported;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(imported == 0 ? '没有新增站点（可能已存在或缺少地址）' : '已导入 $imported 个站点')),
    );
  }

  static Map<String, dynamic>? _credentialFor(PtdImportEntry entry) {
    final DateTime now = DateTime.now();
    if (entry.cookieString != null && entry.cookieString!.isNotEmpty) {
      return <String, dynamic>{
        'type': SiteAuthType.cookie.name,
        'cookie': entry.cookieString,
        'source': 'ptd-backup',
        'updatedAt': now.toIso8601String(),
      };
    }
    if (entry.apiKey != null && entry.apiKey!.isNotEmpty) {
      return <String, dynamic>{
        'type': SiteAuthType.apiKey.name,
        'apiKey': entry.apiKey,
        'source': 'ptd-backup',
        'updatedAt': now.toIso8601String(),
      };
    }
    if (entry.passkey != null && entry.passkey!.isNotEmpty) {
      return <String, dynamic>{
        'type': SiteAuthType.passkey.name,
        'passkey': entry.passkey,
        'source': 'ptd-backup',
        'updatedAt': now.toIso8601String(),
      };
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PtdImportResult? result = _result;

    return Scaffold(
      appBar: AppBar(
        title: const Text('导入 PTD 备份'),
        leading: IconButton(icon: const Icon(Icons.close), tooltip: '取消', onPressed: _leave),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '备份内容',
            subtitle: '直接选 PTD / PT-depiler 导出的 zip 备份，App 自行挑出其中要用的成员；也可粘贴单个 JSON',
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _importing ? null : _pickFile,
                      icon: const Icon(Icons.folder_open, size: AppSizes.iconSm),
                      label: const Text('选择备份文件'),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    if (_fileName != null)
                      Expanded(
                        child: Text(
                          _fileName!,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.error_outline, size: AppSizes.iconSm, color: AppColors.danger),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(_error!, style: theme.textTheme.bodySmall)),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _text,
                  minLines: 6,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    labelText: '备份 JSON',
                    hintText: '{"sites": [{"name": "...", "baseUrl": "...", "cookie": "..."}]}',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _parse,
                      icon: const Icon(Icons.playlist_add_check, size: AppSizes.iconSm),
                      label: const Text('解析备份'),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    if (result != null)
                      TextButton(
                        onPressed: () => setState(() => _text.clear()),
                        child: const Text('清空'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (result != null && result.members.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '备份成员处理情况',
              subtitle:
                  '共 ${result.members.length} 个成员：采用 ${result.usedMembers.length} 个、忽略 ${result.ignoredMembers.length} 个',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final PtdMemberSummary member in result.members)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              member.name,
                              style: theme.textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          StatusBadge(
                            label: member.label,
                            tone: member.used ? StatusTone.ok : StatusTone.neutral,
                            compact: true,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (result != null) ...<Widget>[
            const SizedBox(height: AppSpacing.lg),
            SectionCard(
              title: '解析结果',
              subtitle: '共 ${result.entries.length} 条，可导入 ${result.importableEntries.length} 条',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final String warning in result.warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(Icons.info_outline, size: AppSizes.iconSm, color: AppColors.warning),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(child: Text(warning, style: theme.textTheme.bodySmall)),
                        ],
                      ),
                    ),
                  for (final PtdImportEntry entry in result.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(entry.name, style: theme.textTheme.bodyMedium),
                                if (entry.baseUrl != null)
                                  Text(entry.baseUrl!, style: theme.textTheme.bodySmall),
                                if (entry.sources.isNotEmpty)
                                  Text(
                                    '来自：${entry.sources.join('、')}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                if (entry.notes.isNotEmpty)
                                  Text(
                                    entry.notes.join('；'),
                                    style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning),
                                  ),
                              ],
                            ),
                          ),
                          StatusBadge(
                            label: entry.importable ? (entry.hasCredential ? '可导入（含凭据）' : '可导入') : '已跳过',
                            tone: entry.importable ? StatusTone.ok : StatusTone.neutral,
                            compact: true,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: AppSpacing.md),
                  if (result.importableEntries.isNotEmpty)
                    FilledButton.icon(
                      onPressed: _importing ? null : _importAll,
                      icon: const Icon(Icons.download_done, size: AppSizes.iconSm),
                      label: Text(_importing ? '导入中…' : '导入全部可导入条目'),
                    ),
                  if (_importedCount != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.sm),
                    Text('本次新增 $_importedCount 个站点', style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}