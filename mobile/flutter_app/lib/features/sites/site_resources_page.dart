import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/direct/nexusphp_client.dart';
import '../../core/models/moviepilot.dart';
import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../settings/status_providers.dart';
import 'site_providers.dart';

/// 站点资源：从站点拉取到的信息与资源列表（点站点卡片进入的页面）。
///
/// 页面分三块：
/// 1. **站点概况**：地址、适配定义、认证方式、最近测试与最近刷新时间；
/// 2. **账号数据**：直连站点用户页取到的等级、上传 / 下载、分享率、魔力、做种、
///    今日增量、等级路线与保号口径（取不到的字段标「未采集」）；
/// 3. **资源列表**：直连该站 `torrents.php` 拉取最新资源（可关键词检索），
///    每条资源可点开看详情并推送到下载器。
///
/// 该页面的数据全部来自 App 直连；NAS 后端可用时由 `profileDataProvider` 回退补齐账号数据。
class SiteResourcesPage extends ConsumerStatefulWidget {
  const SiteResourcesPage({super.key, required this.siteId});

  final String siteId;

  @override
  ConsumerState<SiteResourcesPage> createState() => _SiteResourcesPageState();
}

class _SiteResourcesPageState extends ConsumerState<SiteResourcesPage> {
  final TextEditingController _keyword = TextEditingController();
  int _page = 1;
  String _query = '';

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.sites);
    }
  }

  void _search() {
    setState(() {
      _query = _keyword.text.trim();
      _page = 1;
    });
    ref.invalidate(siteResourcesProvider((siteId: widget.siteId, keyword: _query, page: 1)));
  }

  Future<void> _openSite(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      _snack('站点地址无效：$url');
      return;
    }
    final bool ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _snack('无法打开 $url（请检查浏览器是否可用）');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PtSite? site = ref.watch(siteByIdProvider(widget.siteId));
    final AsyncValue<PtDataSnapshot> dataAsync = ref.watch(profileDataProvider);
    final SiteStats? stats = dataAsync.valueOrNull?.sites
        .where((SiteStats s) => s.siteId == widget.siteId)
        .firstOrNull;

    if (site == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('站点资源'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        ),
        body: ErrorStateView(
          title: '站点不存在',
          message: '该站点可能已被删除，返回列表重新选择。',
          onRetry: _leave,
        ),
      );
    }

    final AsyncValue<SearchPageResult> resourcesAsync = ref.watch(
      siteResourcesProvider((siteId: widget.siteId, keyword: _query, page: _page)),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(site.name),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新该站数据',
            onPressed: () => ref
                .read(siteRefreshControllerProvider.notifier)
                .refreshSite(widget.siteId)
                .then((_) => ref.invalidate(siteResourcesProvider)),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '编辑站点',
            onPressed: () => context.go(AppRoutes.siteDetailPath(site.id)),
            icon: const Icon(Icons.edit_outlined),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: <Widget>[
          _overviewCard(theme, site),
          const SizedBox(height: AppSpacing.md),
          _accountCard(theme, stats),
          const SizedBox(height: AppSpacing.md),
          _resourcesSection(theme, site, resourcesAsync),
        ],
      ),
    );
  }

  /// 站点概况：地址、适配定义、认证方式与最近动作时间。
  Widget _overviewCard(ThemeData theme, PtSite site) {
    return SectionCard(
      title: '站点概况',
      subtitle: site.baseUrl,
      trailing: StatusBadge(
        label: site.health.label,
        tone: switch (site.health) {
          SiteHealth.ok => StatusTone.ok,
          SiteHealth.warning => StatusTone.warning,
          SiteHealth.danger => StatusTone.danger,
          SiteHealth.unknown => StatusTone.neutral,
        },
        compact: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xxs,
            children: <Widget>[
              StatusBadge(label: site.framework.label, tone: StatusTone.info, compact: true),
              StatusBadge(label: site.authType.label, tone: StatusTone.neutral, compact: true),
              StatusBadge(
                label: site.credentialConfigured ? '凭据已配置' : '待录凭据',
                tone: site.credentialConfigured ? StatusTone.ok : StatusTone.warning,
                compact: true,
              ),
              if (site.favorite) const StatusBadge(label: '已收藏', tone: StatusTone.ok, compact: true),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '最近测试：${site.lastTestedAt == null ? '未测试' : formatDateTime(site.lastTestedAt!)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: () => _openSite(site.baseUrl),
                icon: const Icon(Icons.open_in_new, size: AppSizes.iconSm),
                label: const Text('打开站点'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.go(AppRoutes.siteDetailPath(site.id)),
                icon: const Icon(Icons.edit_outlined, size: AppSizes.iconSm),
                label: const Text('编辑站点'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 账号数据：直连站点用户页取到的信息（缺字段标「未采集」）。
  Widget _accountCard(ThemeData theme, SiteStats? stats) {
    if (stats == null) {
      return const SectionCard(
        title: '账号数据',
        child: Text('该站账号数据暂未取到：可在右上角刷新重试，或到站点里补齐 Cookie / API Key。'),
      );
    }
    final List<(String, String)> items = <(String, String)>[
      ('用户名', stats.username.isEmpty ? '未采集' : stats.username),
      ('等级', stats.userClass.isEmpty ? '未采集' : stats.userClass),
      ('上传', formatBytes(stats.uploadedBytes)),
      ('下载', formatBytes(stats.downloadedBytes)),
      ('分享率', stats.ratioLabel),
      ('今日上传', stats.todayUploadLabel),
      ('今日下载', stats.todayDownloadLabel),
      ('魔力', formatNumber(stats.bonus)),
      ('做种', '${stats.seedingCount}'),
      ('下载中', '${stats.leechingCount}'),
      ('时魔', stats.hourlyBonus > 0 ? '${stats.hourlyBonusLabel}（本地估算）' : '未采集'),
      ('邀请数', '${stats.invites}'),
      ('邮件数', '${stats.unreadMessages}'),
      ('HR 情况', stats.hrLabel),
      ('加入时间', stats.joinDate == null ? '未采集' : formatDate(stats.joinDate!)),
      ('签到', stats.signInStatusLabel),
    ];
    return SectionCard(
      title: '账号数据',
      subtitle: stats.refreshedAt == null
          ? '来源：直连站点用户页'
          : '来源：直连站点用户页 · 刷新于 ${formatDateTime(stats.refreshedAt!)}',
      trailing: StatusBadge(
        label: stats.careState.label,
        tone: switch (stats.careState) {
          CareState.healthy => StatusTone.ok,
          CareState.attention => StatusTone.warning,
          CareState.atRisk => StatusTone.danger,
          CareState.unknown => StatusTone.neutral,
        },
        compact: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < items.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: _InfoCell(label: items[i].$1, value: items[i].$2)),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: i + 1 < items.length
                        ? _InfoCell(label: items[i + 1].$1, value: items[i + 1].$2)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          if (stats.levelSteps.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            _levelLadder(theme, stats),
          ],
          if (stats.refreshMessage.isNotEmpty &&
              stats.refreshState != SiteRefreshState.refreshed) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(
              stats.refreshMessage,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _levelLadder(ThemeData theme, SiteStats stats) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('等级路线（内置口径估算）', style: theme.textTheme.labelSmall),
          const SizedBox(height: AppSpacing.xxs),
          for (final LevelStep step in stats.levelSteps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    step.achieved ? Icons.check_circle_outline : Icons.radio_button_unchecked,
                    size: AppSizes.iconSm,
                    color: step.achieved
                        ? StatusTone.ok.resolve(theme.brightness)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(step.name, style: theme.textTheme.bodySmall),
                        Text(step.requirement, style: theme.textTheme.labelSmall),
                        if (!step.achieved && step.remaining.isNotEmpty)
                          Text(
                            '还差：${step.remaining}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: StatusTone.warning.resolve(theme.brightness),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 资源列表：直连站点 `torrents.php`（无关键词 = 该站最新资源）。
  Widget _resourcesSection(
    ThemeData theme,
    PtSite site,
    AsyncValue<SearchPageResult> resourcesAsync,
  ) {
    return SectionCard(
      title: '站点资源',
      subtitle: _query.isEmpty ? '该站最新资源（直连站点列表页）' : '关键词「$_query」的站内结果',
      trailing: resourcesAsync.valueOrNull == null
          ? null
          : StatusBadge(
              label: '${resourcesAsync.valueOrNull!.items.length} 条',
              tone: StatusTone.info,
              compact: true,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _keyword,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: '在该站检索（留空看最新资源）',
              prefixIcon: const Icon(Icons.search, size: AppSizes.iconLg),
              suffixIcon: IconButton(
                tooltip: '检索',
                icon: const Icon(Icons.arrow_forward, size: AppSizes.iconMd),
                onPressed: _search,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          resourcesAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: LoadingStateView(message: '正在读取站点资源'),
            ),
            error: (Object error, StackTrace stackTrace) => ErrorStateView(
              title: '资源获取失败',
              message: error is SiteFetchException ? error.message : '$error',
              onRetry: () => ref.invalidate(
                siteResourcesProvider((siteId: widget.siteId, keyword: _query, page: _page)),
              ),
            ),
            data: (SearchPageResult result) => result.items.isEmpty
                ? Text(
                    _query.isEmpty ? '该站没有返回资源' : '没有匹配「$_query」的资源',
                    style: theme.textTheme.bodySmall,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (final SearchResultItem item in result.items)
                        _ResourceRow(item: item, masked: false),
                      const SizedBox(height: AppSpacing.xs),
                      Row(
                        children: <Widget>[
                          Text('第 $_page 页', style: theme.textTheme.labelSmall),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _page > 1 ? () => setState(() => _page -= 1) : null,
                            icon: const Icon(Icons.chevron_left, size: AppSizes.iconSm),
                            label: const Text('上一页'),
                          ),
                          TextButton.icon(
                            onPressed: result.hasMore
                                ? () => setState(() => _page += 1)
                                : null,
                            icon: const Icon(Icons.chevron_right, size: AppSizes.iconSm),
                            label: const Text('下一页'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _InfoCell extends StatelessWidget {
  const _InfoCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(value, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

/// 资源列表中的一行：标题 + 促销 / 大小 / 做种 / 时间。
class _ResourceRow extends StatelessWidget {
  const _ResourceRow({required this.item, required this.masked});

  final SearchResultItem item;
  final bool masked;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    String value(String text) => masked ? '•••' : text;
    return InkWell(
      // 与搜索结果一致：推入根导航器的资源详情页（可看详情并推送到下载器）。
      onTap: () => context.push(AppRoutes.torrentDetailPath, extra: item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              item.title,
              style: theme.textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xxs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xxs,
              children: <Widget>[
                if (item.promotion.isPromotion)
                  StatusBadge(
                    label: item.promotion.label,
                    tone: StatusTone.ok,
                    compact: true,
                  ),
                if (item.category.isNotEmpty)
                  StatusBadge(label: item.category, tone: StatusTone.neutral, compact: true),
                Text(value(formatBytes(item.sizeBytes)), style: theme.textTheme.labelSmall),
                Text('做种 ${value('${item.seeders}')}', style: theme.textTheme.labelSmall),
                Text('下载 ${value('${item.leechers}')}', style: theme.textTheme.labelSmall),
                if (item.publishedAt != null)
                  Text(formatDateTime(item.publishedAt!), style: theme.textTheme.labelSmall),
              ],
            ),
            const Divider(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }
}