import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/downloader.dart';
import '../../core/models/moviepilot.dart';
import '../../core/router/app_routes.dart';
import '../../core/storage/favorite_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import '../downloaders/downloader_providers.dart';
import 'push_sheet.dart';
import 'search_providers.dart';

/// 资源情况展示与推送（需求 18：单击结果进入该资源的情况展示，
/// 界面含"选择下载器、保存目录"，点击开始推送到对应下载器并下载到指定路径）。
class SearchResultDetailPage extends ConsumerStatefulWidget {
  const SearchResultDetailPage({super.key, required this.item});

  /// 由路由 extra 传入的搜索结果；为空时页面提示数据缺失。
  final SearchResultItem? item;

  @override
  ConsumerState<SearchResultDetailPage> createState() => _SearchResultDetailPageState();
}

class _SearchResultDetailPageState extends ConsumerState<SearchResultDetailPage> {
  final TextEditingController _savePath = TextEditingController();
  String? _downloaderId;
  bool _initialized = false;
  bool _pushing = false;

  @override
  void dispose() {
    _savePath.dispose();
    super.dispose();
  }

  void _ensureSelection() {
    if (_initialized) return;
    _initialized = true;
    final List<DownloaderContext> downloaders = _downloaders();
    if (downloaders.isEmpty) return;
    final DownloaderContext first = downloaders.firstWhere(
      (DownloaderContext d) => d.enabled,
      orElse: () => downloaders.first,
    );
    _downloaderId = first.id;
    _savePath.text = first.defaultSavePath;
  }

  List<DownloaderContext> _downloaders() {
    final List<DownloaderConfig> list =
        ref.watch(downloaderListProvider).valueOrNull ?? const <DownloaderConfig>[];
    return list
        .map((DownloaderConfig d) => DownloaderContext(
              id: d.id,
              name: d.name,
              defaultSavePath: d.defaultSavePath,
              enabled: d.enabled,
            ))
        .toList(growable: false);
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.search);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _push() async {
    final SearchResultItem? item = widget.item;
    if (item == null) return;
    if (_downloaderId == null) {
      _snack('请选择下载器');
      return;
    }
    if (item.downloadUrl.isEmpty) {
      _snack('该结果没有可用的下载地址');
      return;
    }
    setState(() => _pushing = true);
    try {
      await pushFromSearchApi(
        ref,
        item: item,
        downloaderId: _downloaderId!,
        savePath: _savePath.text.trim(),
        mpInstanceId: item.isFromMoviePilot && item.siteId.startsWith('mp:')
            ? item.siteId.substring(3)
            : null,
      );
      if (!mounted) return;
      setState(() => _pushing = false);
      _snack('已推送，下载到 ${_savePath.text.trim().isEmpty ? '下载器默认目录' : _savePath.text.trim()}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _pushing = false);
      _snack('推送失败：$error');
    }
  }

  Future<void> _toggleFavorite(SearchResultItem item) async {
    final bool now =
        await ref.read(favoritesProvider.notifier).toggle(FavoriteItem.fromSearchResult(item));
    if (!mounted) return;
    _snack(now ? '已收藏' : '已取消收藏');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SearchResultItem? item = widget.item;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('资源情况'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        ),
        body: const Center(child: Text('资源数据缺失，请从搜索结果重新进入。')),
      );
    }

    final List<DownloaderContext> downloaders = _downloaders();
    _ensureSelection();
    final bool favorited = ref.watch(favoritesProvider).valueOrNull
            ?.any((FavoriteItem f) => f.key == item.favoriteKey) ??
        false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('资源情况'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        actions: <Widget>[
          IconButton(
            tooltip: favorited ? '取消收藏' : '收藏',
            onPressed: () => _toggleFavorite(item),
            icon: Icon(favorited ? Icons.star : Icons.star_border),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: item.title,
            subtitle: item.subtitle.isEmpty ? '来自 ${item.siteName}' : item.subtitle,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xxs,
                  children: <Widget>[
                    StatusBadge(
                      label: item.siteName.isEmpty ? '未知站点' : item.siteName,
                      tone: StatusTone.info,
                      compact: true,
                    ),
                    if (item.promotion.isPromotion)
                      StatusBadge(label: item.promotion.label, tone: StatusTone.warning, compact: true),
                    if (item.isFromMoviePilot)
                      const StatusBadge(label: '来自 MoviePilot', tone: StatusTone.ok, compact: true),
                    if (item.category.isNotEmpty)
                      StatusBadge(label: item.category, tone: StatusTone.neutral, compact: true),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _InfoRow(label: '大小', value: formatBytes(item.sizeBytes)),
                _InfoRow(label: '做种', value: '${item.seeders}'),
                _InfoRow(label: '下载', value: '${item.leechers}'),
                _InfoRow(
                  label: '发布时间',
                  value: item.publishedAt == null ? '未知' : _formatDate(item.publishedAt!),
                ),
                _InfoRow(
                  label: '下载地址',
                  value: item.downloadUrl.isEmpty ? '服务端未提供' : '由 NAS 后端携带凭据抓取',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '推送到下载器',
            subtitle: '选择下载器与保存目录，点击开始推送（需求 18）',
            child: downloaders.isEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('还没有可用的下载器，请先在「下载器」里添加。', style: theme.textTheme.bodySmall),
                      const SizedBox(height: AppSpacing.md),
                      OutlinedButton.icon(
                        onPressed: () => context.go(AppRoutes.downloaders),
                        icon: const Icon(Icons.download_outlined, size: AppSizes.iconSm),
                        label: const Text('前往下载器'),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: <Widget>[
                          for (final DownloaderContext config in downloaders)
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
                        '留空时使用下载器的默认目录；目录由 NAS 后端下发给下载器。',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _pushing ? null : _push,
                          icon: const Icon(Icons.download, size: AppSizes.iconSm),
                          label: Text(_pushing ? '推送中…' : '开始推送'),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}

/// 下载器的展示上下文（页面内使用，避免直接依赖完整配置模型）。
class DownloaderContext {
  const DownloaderContext({
    required this.id,
    required this.name,
    required this.defaultSavePath,
    required this.enabled,
  });

  final String id;
  final String name;
  final String defaultSavePath;
  final bool enabled;
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