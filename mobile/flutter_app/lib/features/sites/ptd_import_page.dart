import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/pt_site.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/platform_file_picker.dart';
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
  int _credentialFilledCount = 0;
  int _skippedCount = 0;

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
    const PlatformFilePicker picker = PlatformFilePicker();
    if (!picker.isSupported) {
      setState(() => _error = '当前平台没有系统文件选择器，请改用下面的「粘贴备份 JSON」方式导入');
      return;
    }
    try {
      final PickedFileData? picked = await picker.pick();
      if (picked == null) return; // 用户取消
      final PtdImportResult result = ref.read(ptdImporterProvider).parseBytes(picked.bytes);
      if (!mounted) return;
      setState(() {
        _result = result;
        _fileName = picked.name;
        _importedCount = null;
        _error = null;
      });
    } on MissingPluginException {
      if (!mounted) return;
      setState(() => _error = '当前平台没有系统文件选择器，请改用下面的「粘贴备份 JSON」方式导入');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '选择文件失败：$error');
    }
  }

  Future<void> _importAll() async {
    final PtdImportResult? result = _result;
    if (result == null) return;

    final SiteListNotifier notifier = ref.read(siteListProvider.notifier);
    // 先按本机安全存储校正一次「是否已配置凭据」：否则「本机其实有凭据、标记却是未配置」的
    // 站点会被误判成缺凭据，进而被备份里的旧登录态覆盖。
    await notifier.reconcileCredentials();

    final List<PtSite> existing = ref.read(siteListProvider).valueOrNull ?? const <PtSite>[];
    final Map<String, PtSite> existingByHost = <String, PtSite>{
      for (final PtSite s in existing) s.host.toLowerCase(): s,
    };
    int created = 0;
    int credentialFilled = 0;
    int skipped = 0;

    setState(() => _importing = true);
    for (final PtdImportEntry entry in result.importableEntries) {
      final Uri? uri = SiteReachabilityProbe.parseSiteUri(entry.baseUrl!);
      if (uri == null) continue;
      final String host = uri.host.toLowerCase();
      final Map<String, dynamic>? credential = _credentialFor(entry);
      final PtSite? target = existingByHost[host];

      if (target == null) {
        // 新站点：建站 + 写凭据（认证方式按实际写进去的凭据类型决定，避免标记与内容不一致）。
        final String id = const Uuid().v4();
        await notifier.upsert(
          PtSite(
            id: id,
            name: entry.name,
            baseUrl: uri.toString(),
            authType: _authTypeFor(credential, fallbackName: entry.cookieString != null ? 'cookie' : null),
            credentialConfigured: credential != null,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        if (credential != null) {
          await notifier.saveCredential(id, credential);
        }
        existingByHost[host] = PtSite(
          id: id,
          name: entry.name,
          baseUrl: uri.toString(),
          credentialConfigured: credential != null,
        );
        created++;
        continue;
      }

      // 已有站点：备份里有凭据而本机还没有时补齐凭据。
      // 不覆盖本机已保存的凭据（可能是更新的登录态），也不改动站点名称与地址。
      if (credential != null && !target.credentialConfigured) {
        await notifier.saveCredential(target.id, credential);
        if (_authTypeFor(credential, fallbackName: null) != target.authType) {
          await notifier.upsert(
            target.copyWith(authType: _authTypeFor(credential, fallbackName: null)),
          );
        }
        existingByHost[host] = target.copyWith(credentialConfigured: true);
        credentialFilled++;
        continue;
      }
      skipped++;
    }

    if (!mounted) return;
    setState(() {
      _importing = false;
      _importedCount = created;
      _credentialFilledCount = credentialFilled;
      _skippedCount = skipped;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_summary(created, credentialFilled, skipped))),
    );
  }

  static String _summary(int created, int filled, int skipped) {
    final List<String> parts = <String>[
      if (created > 0) '新增 $created 个站点',
      if (filled > 0) '为 $filled 个已有站点补齐凭据',
      if (skipped > 0) '$skipped 个已有站点保留本机凭据',
    ];
    if (parts.isEmpty) return '没有可导入的站点（备份里缺少地址）';
    return '导入完成：${parts.join('，')}';
  }

  /// 认证方式按真正写进去的凭据类型决定，避免出现「认证方式是 Cookie、内容却是 API Key」。
  static SiteAuthType _authTypeFor(Map<String, dynamic>? credential, {String? fallbackName}) {
    final String type = credential?['type']?.toString() ?? fallbackName ?? '';
    return switch (type) {
      'apiKey' => SiteAuthType.apiKey,
      'passkey' => SiteAuthType.passkey,
      'cookie' => SiteAuthType.cookie,
      'account' => SiteAuthType.account,
      _ => SiteAuthType.cookie,
    };
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
                    Text(
                      '本次新增 $_importedCount 个站点'
                      '${_credentialFilledCount > 0 ? '，为 $_credentialFilledCount 个已有站点补齐凭据' : ''}'
                      '${_skippedCount > 0 ? '，$_skippedCount 个已有站点保留本机凭据' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
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