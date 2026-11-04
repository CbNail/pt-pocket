import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/moviepilot.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/storage/favorite_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import 'push_sheet.dart';
import 'search_providers.dart';

/// 搜索页：多站聚合搜索与结果交互（需求 4、8、18）。
///
/// 交互：
/// - 单击结果 → 进入资源情况页（选择下载器与保存目录后推送）；
/// - 长按结果 → 弹出推送下载器面板；
/// - 向左滑动 → 展示「下载」与「收藏」。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit(String value) => ref.read(searchControllerProvider.notifier).submit(value);

  void _useHistory(String keyword) {
    _controller.text = keyword;
    _submit(keyword);
  }

  Future<void> _toggleFavorite(SearchResultItem item) async {
    final bool now =
        await ref.read(favoritesProvider.notifier).toggle(FavoriteItem.fromSearchResult(item));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(now ? '已收藏「${item.title}」' : '已取消收藏')),
    );
  }

  Future<void> _openDetail(SearchResultItem item) =>
      context.push(AppRoutes.torrentDetailPath, extra: item);

  @override
  Widget build(BuildContext context) {
    final SearchState state = ref.watch(searchControllerProvider);
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;
    final int enhanceCount = ref.watch(searchEnhanceInstanceIdsProvider).length;
    final List<FavoriteItem> favorites = ref.watch(favoritesProvider).valueOrNull ?? const <FavoriteItem>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () => context.go(AppRoutes.settingsMoviePilotPath),
            icon: const Icon(Icons.auto_awesome, size: AppSizes.iconSm),
            label: Text('MP 增强 ${enhanceCount > 0 ? '· $enhanceCount' : ''}'),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              textInputAction: TextInputAction.search,
              onSubmitted: _submit,
              decoration: InputDecoration(
                hintText: '片名 / 关键词 / 站点内编号',
                prefixIcon: const Icon(Icons.search, size: AppSizes.iconLg),
                suffixIcon: state.hasKeyword
                    ? IconButton(
                        icon: const Icon(Icons.close, size: AppSizes.iconMd),
                        onPressed: () {
                          _controller.clear();
                          ref.read(searchControllerProvider.notifier).clearKeyword();
                        },
                      )
                    : null,
              ),
            ),
          ),
          _FilterBar(
            scope: state.scope,
            promotion: state.promotion,
            sort: state.sort,
            onScope: (SearchScope v) => ref.read(searchControllerProvider.notifier).setScope(v),
            onPromotion: (PromotionFilter v) =>
                ref.read(searchControllerProvider.notifier).setPromotion(v),
            onSort: (SortOption v) => ref.read(searchControllerProvider.notifier).setSort(v),
          ),
          const Divider(height: 1),
          Expanded(child: _body(state, nasConfigured, favorites)),
        ],
      ),
    );
  }

  Widget _body(SearchState state, bool nasConfigured, List<FavoriteItem> favorites) {
    if (state.scope == SearchScope.favorites) return _favoritesView(favorites);
    if (!nasConfigured) {
      return const EmptyStateView(
        icon: Icons.link_off,
        title: '尚未连接 NAS 服务',
        message: '聚合搜索由 NAS 后端并发查询各站点，请先完成服务配对。',
      );
    }
    if (!state.hasKeyword) return _historyView(state.history);
    if (state.error != null) {
      return ErrorStateView(
        title: '搜索失败',
        message: state.error!,
        onRetry: () => ref.read(searchControllerProvider.notifier).retry(),
      );
    }
    if (state.loading) return const LoadingStateView(message: '正在并发检索各站点');
    if (state.streaming) return _streamView(state);

    final SearchPageResult? result = state.result;
    if (result == null || result.items.isEmpty) {
      return EmptyStateView(
        icon: Icons.search_off,
        title: '暂无「${state.keyword}」的结果',
        message: '可调整筛选条件，或确认相关站点已在站点模块启用。',
      );
    }
    return _resultsView(result);
  }

  /// 逐站（实时）模式：进度条常驻顶部，结果列表边搜边出。
  Widget _streamView(SearchState state) {
    final SearchPageResult? result = state.result;
    return Column(
      children: <Widget>[
        _SearchProgressBar(
          state: state,
          onStop: () => ref.read(searchControllerProvider.notifier).stop(),
          onRestart: () => ref.read(searchControllerProvider.notifier).retry(),
          onStatus: () => _showSearchStatus(state),
        ),
        Expanded(
          child: result == null || result.items.isEmpty
              ? LoadingStateView(
                  message: state.running
                      ? '正在检索各站点，结果会逐站出现'
                      : '本次搜索没有返回结果',
                )
              : _resultsView(result, streaming: true, running: state.running),
        ),
      ],
    );
  }

  Future<void> _showSearchStatus(SearchState state) async {
    final List<SiteSearchStatus> statuses = state.progress.values.toList(growable: false)
      ..sort((SiteSearchStatus a, SiteSearchStatus b) {
        if (a.phase == b.phase) return a.siteName.compareTo(b.siteName);
        return a.phase.index.compareTo(b.phase.index);
      });
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('搜索状态'),
        content: SizedBox(
          width: 420,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: statuses.length,
            separatorBuilder: (BuildContext context, int index) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final SiteSearchStatus status = statuses[index];
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(status.siteName.isEmpty ? status.siteId : status.siteName),
                subtitle: status.message.isEmpty ? null : Text(status.message),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (status.phase == SiteSearchPhase.success)
                      Text('${status.itemCount} 条', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: AppSpacing.xs),
                    StatusBadge(
                      label: status.phase.label,
                      tone: switch (status.phase) {
                        SiteSearchPhase.success => StatusTone.ok,
                        SiteSearchPhase.failed => StatusTone.danger,
                        SiteSearchPhase.working => StatusTone.info,
                        SiteSearchPhase.queued => StatusTone.neutral,
                        SiteSearchPhase.cancelled => StatusTone.warning,
                      },
                      compact: true,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _historyView(List<String> history) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.travel_explore, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('输入关键词开始搜索', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '结果按站点逐步返回并自动去重；单击查看资源情况，长按或左滑可直接推送与收藏。',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            if (history.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  for (final String keyword in history)
                    ActionChip(
                      label: Text(keyword),
                      onPressed: () => _useHistory(keyword),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _favoritesView(List<FavoriteItem> favorites) {
    if (favorites.isEmpty) {
      return const EmptyStateView(
        icon: Icons.star_border,
        title: '还没有收藏的资源',
        message: '在搜索结果上向左滑动或点开资源后即可收藏。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
      itemCount: favorites.length,
      separatorBuilder: (BuildContext context, int index) => const SizedBox(height: AppSpacing.cardGap),
      itemBuilder: (BuildContext context, int index) {
        final FavoriteItem favorite = favorites[index];
        final SearchResultItem item = favorite.toSearchResultItem();
        return Slidable(
          key: ValueKey<String>(favorite.key),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            extentRatio: 0.44,
            children: <Widget>[
              SlidableAction(
                onPressed: (BuildContext context) => showPushSheet(context, ref: ref, item: item),
                backgroundColor: AppColors.brand,
                foregroundColor: const Color(0xFF04231A),
                icon: Icons.download,
                label: '下载',
              ),
              SlidableAction(
                onPressed: (BuildContext context) async {
                  await ref.read(favoritesProvider.notifier).remove(favorite.key);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已取消收藏')),
                  );
                },
                backgroundColor: AppColors.warning,
                foregroundColor: const Color(0xFF2A1A00),
                icon: Icons.star_border,
                label: '取消收藏',
              ),
            ],
          ),
          child: _resultTile(
            item,
            subtitleOverride: '${favorite.siteName} · ${formatBytes(favorite.sizeBytes)}',
            favorited: true,
          ),
        );
      },
    );
  }

  Widget _resultsView(SearchPageResult result, {bool streaming = false, bool running = false}) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
      children: <Widget>[
        if (result.hasSiteErrors)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: PartialResultBanner(
              message: '${result.siteErrors.length} 个站点本次未返回结果：'
                  '${result.siteErrors.entries.map((MapEntry<String, String> e) => '${e.key}（${e.value}）').join('、')}',
            ),
          ),
        if (result.notice.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(result.notice, style: theme.textTheme.bodySmall),
          ),
        for (final SearchResultItem item in result.items)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.cardGap),
            child: Slidable(
              key: ValueKey<String>(item.favoriteKey),
              endActionPane: ActionPane(
                motion: const DrawerMotion(),
                extentRatio: 0.44,
                children: <Widget>[
                  SlidableAction(
                    onPressed: (BuildContext context) =>
                        showPushSheet(context, ref: ref, item: item),
                    backgroundColor: AppColors.brand,
                    foregroundColor: const Color(0xFF04231A),
                    icon: Icons.download,
                    label: '下载',
                  ),
                  SlidableAction(
                    onPressed: (BuildContext context) => _toggleFavorite(item),
                    backgroundColor: AppColors.warning,
                    foregroundColor: const Color(0xFF2A1A00),
                    icon: Icons.star,
                    label: '收藏',
                  ),
                ],
              ),
              child: _resultTile(
                item,
                favorited: ref.read(favoritesProvider.notifier).contains(item.favoriteKey),
              ),
            ),
          ),
        if (result.hasMore && !running)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: TextButton.icon(
                onPressed: ref.read(searchControllerProvider.notifier).loadMore,
                icon: const Icon(Icons.expand_more, size: AppSizes.iconSm),
                label: const Text('加载更多'),
              ),
            ),
          )
        else
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(
                streaming
                    ? (running
                        ? '已收到 ${result.items.length} 条，仍在检索其余站点'
                        : '共 ${result.items.length} 条结果')
                    : '已显示 ${result.items.length} 条结果',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
      ],
    );
  }

  /// 单条结果：单击进入资源情况，长按弹出推送面板。
  Widget _resultTile(
    SearchResultItem item, {
    required bool favorited,
    String? subtitleOverride,
  }) {
    final ThemeData theme = Theme.of(context);
    final String subtitle = subtitleOverride ??
        '${item.siteName} · ${formatBytes(item.sizeBytes)} · 做种 ${item.seeders}';

    return GestureDetector(
      onLongPress: () => showPushSheet(context, ref: ref, item: item),
      child: SectionCard(
        onTap: () => _openDetail(item),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    item.title,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (favorited) ...<Widget>[
                  const SizedBox(width: AppSpacing.xs),
                  const Icon(Icons.star, size: AppSizes.iconSm, color: AppColors.warning),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.xxs),
            Text(subtitle, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xxs,
              children: <Widget>[
                if (item.promotion.isPromotion)
                  StatusBadge(label: item.promotion.label, tone: StatusTone.warning, compact: true),
                if (item.isFromMoviePilot)
                  const StatusBadge(label: 'MP', tone: StatusTone.ok, compact: true),
                if (item.category.isNotEmpty)
                  StatusBadge(label: item.category, tone: StatusTone.neutral, compact: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 逐站检索的进度条：进行中显示「已完成 x/y 站 · 已收到 N 条」与「停止」，
/// 停止后保留已收到结果并给出「继续搜索」，同时提供「搜索状态」查看每站结论。
class _SearchProgressBar extends StatelessWidget {
  const _SearchProgressBar({
    required this.state,
    required this.onStop,
    required this.onRestart,
    required this.onStatus,
  });

  final SearchState state;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onStatus;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int done = state.doneSites;
    final int total = state.totalSites;
    final String headline = state.running
        ? '搜索中：已完成 $done/$total 站 · 已收到 ${state.receivedCount} 条'
        : (state.stopped
            ? '已停止：已收到 ${state.receivedCount} 条'
            : '搜索完成：$total 站 · 共 ${state.receivedCount} 条');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (state.running)
                const Padding(
                  padding: EdgeInsets.only(right: AppSpacing.sm),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Expanded(
                child: Text(
                  headline,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: onStatus,
                child: const Text('搜索状态'),
              ),
              if (state.running)
                TextButton(
                  onPressed: onStop,
                  child: const Text('停止'),
                )
              else
                TextButton(
                  onPressed: onRestart,
                  child: const Text('重新搜索'),
                ),
            ],
          ),
          if (state.running)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: LinearProgressIndicator(
                value: total == 0 ? null : done / total,
                minHeight: 4,
              ),
            ),
          if ((state.notice ?? '').isNotEmpty)
            Text(
              state.notice!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: state.failedSites.isEmpty ? null : theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}

/// 筛选条：范围 / 促销 / 排序。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.scope,
    required this.promotion,
    required this.sort,
    required this.onScope,
    required this.onPromotion,
    required this.onSort,
  });

  final SearchScope scope;
  final PromotionFilter promotion;
  final SortOption sort;
  final ValueChanged<SearchScope> onScope;
  final ValueChanged<PromotionFilter> onPromotion;
  final ValueChanged<SortOption> onSort;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        children: <Widget>[
          _dropdown<SearchScope>(
            context,
            icon: Icons.dns_outlined,
            value: scope,
            options: SearchScope.values,
            labelOf: (SearchScope v) => v.label,
            onChanged: onScope,
          ),
          const SizedBox(width: AppSpacing.sm),
          _dropdown<PromotionFilter>(
            context,
            icon: Icons.local_offer_outlined,
            value: promotion,
            options: PromotionFilter.values,
            labelOf: (PromotionFilter v) => v.label,
            onChanged: onPromotion,
          ),
          const SizedBox(width: AppSpacing.sm),
          _dropdown<SortOption>(
            context,
            icon: Icons.sort,
            value: sort,
            options: SortOption.values,
            labelOf: (SortOption v) => v.label,
            onChanged: onSort,
          ),
        ],
      ),
    );
  }

  Widget _dropdown<T>(
    BuildContext context, {
    required IconData icon,
    required T value,
    required List<T> options,
    required String Function(T) labelOf,
    required ValueChanged<T> onChanged,
  }) {
    return Center(
      child: PopupMenuButton<T>(
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (BuildContext context) => options
            .map((T option) => PopupMenuItem<T>(value: option, child: Text(labelOf(option))))
            .toList(growable: false),
        child: Chip(
          avatar: Icon(icon, size: AppSizes.iconSm),
          label: Text(labelOf(value)),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        ),
      ),
    );
  }
}