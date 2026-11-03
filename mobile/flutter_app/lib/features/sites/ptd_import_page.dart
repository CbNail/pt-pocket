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
    });
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
            subtitle: '粘贴 PTD / PT-depiler 导出的 JSON 备份文本',
            child: Column(
              children: <Widget>[
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