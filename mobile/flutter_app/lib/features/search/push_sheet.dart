import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/downloader.dart';
import '../../core/models/moviepilot.dart';
import '../../core/models/pt_site.dart';
import '../../core/network/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/status_badge.dart';
import '../downloaders/downloader_providers.dart';
import '../sites/site_providers.dart';
import 'search_providers.dart';

/// 推送下载器面板（需求 18：长按结果弹出推送框；详情页选择下载器后开始推送）。
///
/// 选下载器 + 填保存目录 → 经 NAS 后端把资源推送到对应下载器。
Future<void> showPushSheet(
  BuildContext context, {
  required WidgetRef ref,
  required SearchResultItem item,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => _PushSheet(item: item),
  );
}

class _PushSheet extends ConsumerStatefulWidget {
  const _PushSheet({required this.item});

  final SearchResultItem item;

  @override
  ConsumerState<_PushSheet> createState() => _PushSheetState();
}

class _PushSheetState extends ConsumerState<_PushSheet> {
  final TextEditingController _savePath = TextEditingController();
  String? _downloaderId;
  bool _pushing = false;
  bool _initialized = false;

  @override
  void dispose() {
    _savePath.dispose();
    super.dispose();
  }

  /// 默认选中第一个启用的下载器，并预填它的默认保存目录。
  void _ensureSelection(List<DownloaderConfig> downloaders) {
    if (_initialized || downloaders.isEmpty) return;
    _initialized = true;
    final DownloaderConfig first =
        downloaders.firstWhere((DownloaderConfig d) => d.enabled, orElse: () => downloaders.first);
    _downloaderId = first.id;
    _savePath.text = first.defaultSavePath;
  }

  Future<void> _push(List<DownloaderConfig> downloaders) async {
    final String? downloaderId = _downloaderId;
    if (downloaderId == null) {
      _snack('请选择下载器');
      return;
    }
    if (widget.item.downloadUrl.isEmpty) {
      _snack('该结果没有可用的下载地址');
      return;
    }
    setState(() => _pushing = true);
    try {
      final String? mpId = widget.item.isFromMoviePilot ? _mpInstanceId() : null;
      await ref.read(searchApiProvider).push(
            downloadUrl: widget.item.downloadUrl,
            downloaderId: downloaderId,
            savePath: _savePath.text.trim(),
            category: widget.item.category,
            mpInstanceId: mpId,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已推送到下载器')),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _pushing = false);
      _snack('推送失败：${error.message}');
    }
  }

  String? _mpInstanceId() {
    final String siteId = widget.item.siteId;
    if (siteId.startsWith('mp:')) return siteId.substring(3);
    return null;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<DownloaderConfig> downloaders =
        ref.watch(downloaderListProvider).valueOrNull ?? const <DownloaderConfig>[];
    _ensureSelection(downloaders);
    final List<PtSite> sites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('推送到下载器', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xxs),
            Text(
              widget.item.title,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.md),
            if (downloaders.isEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('还没有可用的下载器，请先在「下载器」里添加。', style: theme.textTheme.bodySmall),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('知道了'),
                  ),
                ],
              )
            else ...<Widget>[
              Text('选择下载器', style: theme.textTheme.labelLarge),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: <Widget>[
                  for (final DownloaderConfig config in downloaders)
                    ChoiceChip(
                      label: Text(config.name),
                      selected: _downloaderId == config.id,
                      onSelected: (bool selected) {
                        if (!selected) return;
                        setState(() {
                          _downloaderId = config.id;
                          _savePath.text = config.defaultSavePath;
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _savePath,
                decoration: const InputDecoration(
                  labelText: '保存目录',
                  hintText: '/downloads/PT',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '留空时使用下载器默认目录；目录由 NAS 后端下发给下载器。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.lg),
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
                    child: FilledButton.icon(
                      onPressed: _pushing ? null : () => _push(downloaders),
                      icon: const Icon(Icons.download, size: AppSizes.iconSm),
                      label: Text(_pushing ? '推送中…' : '开始推送'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.xs,
              children: <Widget>[
                if (widget.item.siteName.isNotEmpty)
                  StatusBadge(label: widget.item.siteName, tone: StatusTone.info, compact: true),
                if (widget.item.isFromMoviePilot)
                  const StatusBadge(label: '来自 MoviePilot', tone: StatusTone.ok, compact: true),
                StatusBadge(
                  label: '${sites.length} 个站点已启用可搜',
                  tone: StatusTone.neutral,
                  compact: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 从搜索结果或收藏条目推送（供详情页与收藏列表复用）。
Future<void> pushFromSearchApi(
  WidgetRef ref, {
  required SearchResultItem item,
  required String downloaderId,
  String? savePath,
  String? mpInstanceId,
}) =>
    ref.read(searchApiProvider).push(
          downloadUrl: item.downloadUrl,
          downloaderId: downloaderId,
          savePath: savePath,
          category: item.category,
          mpInstanceId: mpInstanceId,
        );