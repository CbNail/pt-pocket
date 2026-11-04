import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../settings/status_providers.dart';
import 'site_providers.dart';

/// 站点页（需求 4）：站点数据面板。
///
/// 面板职责：
/// - 每站展示图标、上传 / 下载 / 分享率 / 做种数 / 综合时魔 / 签到情况 /
///   连接数 / HR 情况 / 邮件数 / 邀请数；
/// - 顶部提供「打码」「扩展」「刷新」「更多（PT 历程）」四个入口；
/// - 支持按「已刷新 / 未刷新 / 失败 / 未登录」四态筛选。
///
/// 数据来源：NAS 后端（`/api/v1/profile` 与 `/api/v1/sites/*/refresh`）。
/// 后端未实现时站点清单仍可用，只是统计数据缺席——面板会明确说明，而不是显示 0 冒充真实值。
class SitesPage extends ConsumerStatefulWidget {
  const SitesPage({super.key});

  @override
  ConsumerState<SitesPage> createState() => _SitesPageState();
}

class _SitesPageState extends ConsumerState<SitesPage> {
  final TextEditingController _query = TextEditingController();
  bool _favoriteFirst = false;

  /// 打码开关：屏蔽所有数值，方便在公共场合查看。
  bool _masked = false;

  /// 扩展展示：打开后每站展示全部指标，关闭时只保留核心几项。
  bool _expanded = false;

  final Set<SiteRefreshState> _refreshFilter = <SiteRefreshState>{};

  String? _testingId;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<PtSite> _visible(List<PtSite> sites, Map<String, SiteStats> stats) {
    final String keyword = _query.text.trim().toLowerCase();
    final List<PtSite> list = sites.where((PtSite s) {
      final bool keywordOk = keyword.isEmpty ||
          s.name.toLowerCase().contains(keyword) ||
          s.host.toLowerCase().contains(keyword);
      if (!keywordOk) return false;
      if (_refreshFilter.isEmpty) return true;
      final SiteRefreshState state = stats[s.id]?.refreshState ?? SiteRefreshState.unknown;
      return _refreshFilter.contains(state);
    }).toList();
    if (_favoriteFirst) {
      list.sort((PtSite a, PtSite b) {
        if (a.favorite == b.favorite) return a.name.compareTo(b.name);
        return a.favorite ? -1 : 1;
      });
    }
    return list;
  }

  Future<void> _test(PtSite site) async {
    setState(() => _testingId = site.id);
    final SiteProbeResult result = await ref.read(siteProbeProvider)(site.baseUrl);
    await ref.read(siteListProvider.notifier).recordProbe(site.id, result);
    if (!mounted) return;
    setState(() => _testingId = null);
    _snack('${site.name}：${result.outcome.label} · ${result.message}');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmDelete(PtSite site) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除站点'),
        content: Text('将删除「${site.name}」及其在本机保存的凭据，操作不可恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(siteListProvider.notifier).remove(site.id);
    if (!mounted) return;
    _snack('已删除「${site.name}」');
  }

  Future<void> _refreshAll() async {
    await ref.read(siteRefreshControllerProvider.notifier).refreshAll();
    if (!mounted) return;
    final SiteRefreshView after = ref.read(siteRefreshControllerProvider);
    _snack(after.error == null ? '已下发站点数据刷新（由 NAS 后端逐个抓取）' : '刷新失败：${after.error}');
  }

  Future<void> _refreshSite(PtSite site) async {
    await ref.read(siteRefreshControllerProvider.notifier).refreshSite(site.id);
    if (!mounted) return;
    final SiteRefreshView after = ref.read(siteRefreshControllerProvider);
    _snack(after.error == null ? '已下发「${site.name}」数据刷新' : '刷新失败：${after.error}');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;
    final AsyncValue<List<PtSite>> sitesAsync = ref.watch(siteListProvider);
    final AsyncValue<PtDataSnapshot> dataAsync = ref.watch(profileDataProvider);
    final SiteRefreshView refreshView = ref.watch(siteRefreshControllerProvider);

    final Map<String, SiteStats> stats = <String, SiteStats>{
      for (final SiteStats item in dataAsync.valueOrNull?.sites ?? const <SiteStats>[])
        item.siteId: item,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('站点'),
        actions: <Widget>[
          IconButton(
            tooltip: _masked ? '取消打码' : '数值打码',
            onPressed: () => setState(() => _masked = !_masked),
            icon: Icon(_masked ? Icons.visibility_off : Icons.visibility),
          ),
          IconButton(
            tooltip: _expanded ? '收起站点信息' : '展开每个站点的信息',
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(_expanded ? Icons.view_compact : Icons.grid_view),
          ),
          IconButton(
            tooltip: '刷新每个站点的数据',
            onPressed: refreshView.busy ? null : _refreshAll,
            icon: refreshView.refreshingAll
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz),
            onSelected: (String action) {
              switch (action) {
                case 'history':
                  context.go(AppRoutes.settingsPtDataPath);
                case 'monitor':
                  context.go(AppRoutes.settingsMonitorPath);
                case 'signin':
                  context.go(AppRoutes.settingsSignInPath);
                case 'favoriteFirst':
                  setState(() => _favoriteFirst = true);
                case 'byName':
                  setState(() => _favoriteFirst = false);
                case 'cookiecloud':
                  context.go(AppRoutes.siteCookieCloudPath);
                case 'ptd':
                  context.go(AppRoutes.sitePtdImportPath);
                case 'reload':
                  ref.invalidate(siteListProvider);
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'history', child: Text('PT 历程与数据统计')),
              const PopupMenuItem<String>(value: 'monitor', child: Text('PT 监护室')),
              const PopupMenuItem<String>(value: 'signin', child: Text('一键签到')),
              const PopupMenuDivider(),
              CheckedPopupMenuItem<String>(
                value: 'favoriteFirst',
                checked: _favoriteFirst,
                child: const Text('排序：收藏优先'),
              ),
              CheckedPopupMenuItem<String>(
                value: 'byName',
                checked: !_favoriteFirst,
                child: const Text('排序：按名称'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(value: 'cookiecloud', child: Text('CookieCloud 一键导入')),
              const PopupMenuItem<String>(value: 'ptd', child: Text('导入 PTD 备份')),
              const PopupMenuItem<String>(value: 'reload', child: Text('重载站点清单')),
            ],
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!nasConfigured)
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
              child: PartialResultBanner(
                message: '尚未配置 NAS 服务地址；站点的数据统计、签到与巡检在完成服务配对后启用。',
              ),
            ),
          if (dataAsync.hasError)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
              child: PartialResultBanner(
                message: '站点数据暂不可用（由 NAS 后端提供）：'
                    '${dataAsync.error is Object ? '${dataAsync.error}' : ''}',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: TextField(
              controller: _query,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索已添加的站点',
                prefixIcon: const Icon(Icons.search, size: AppSizes.iconLg),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: AppSizes.iconMd),
                        onPressed: () {
                          _query.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          _filterBar(theme),
          Expanded(
            child: sitesAsync.when(
              loading: () => const LoadingStateView(message: '正在读取站点清单'),
              error: (Object error, StackTrace stackTrace) => ErrorStateView(
                message: '$error',
                onRetry: () => ref.invalidate(siteListProvider),
              ),
              data: (List<PtSite> sites) => sites.isEmpty
                  ? _emptyView(theme)
                  : _listView(theme, sites, stats, refreshView),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(AppRoutes.siteAddPath),
        icon: const Icon(Icons.add),
        label: const Text('添加站点'),
      ),
    );
  }

  /// 四态筛选：已刷新 / 未刷新 / 失败 / 未登录（可多选，「全部」清空筛选）。
  Widget _filterBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 0),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xxs,
        children: <Widget>[
          FilterChip(
            label: const Text('全部'),
            selected: _refreshFilter.isEmpty,
            onSelected: (bool _) => setState(_refreshFilter.clear),
          ),
          for (final SiteRefreshState state in SiteRefreshState.filterable)
            FilterChip(
              label: Text(state.label),
              selected: _refreshFilter.contains(state),
              onSelected: (bool value) => setState(() {
                if (value) {
                  _refreshFilter.add(state);
                } else {
                  _refreshFilter.remove(state);
                }
              }),
            ),
        ],
      ),
    );
  }

  Widget _emptyView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.dns_outlined, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text('还没有添加站点', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '添加站点后可录入 Cookie / Passkey / API Key，做连接测试，'
              '或从 CookieCloud 与 PTD 备份批量恢复。',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: () => context.go(AppRoutes.siteAddPath),
              icon: const Icon(Icons.add, size: AppSizes.iconSm),
              label: const Text('添加站点'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listView(
    ThemeData theme,
    List<PtSite> sites,
    Map<String, SiteStats> stats,
    SiteRefreshView refreshView,
  ) {
    final List<PtSite> visible = _visible(sites, stats);
    if (visible.isEmpty) {
      return EmptyStateView(
        icon: Icons.search_off,
        title: _refreshFilter.isEmpty ? '没有匹配的站点' : '没有符合筛选状态的站点',
        message: _refreshFilter.isEmpty ? '换个关键词，或清空搜索框。' : '换一个状态筛选，或点「全部」看所有站点。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
      itemCount: visible.length,
      separatorBuilder: (BuildContext context, int index) => const SizedBox(height: AppSpacing.cardGap),
      itemBuilder: (BuildContext context, int index) {
        final PtSite site = visible[index];
        return _SiteTile(
          site: site,
          stats: stats[site.id],
          masked: _masked,
          expanded: _expanded,
          dataMissing: dataAsyncHasError(ref),
          testing: _testingId == site.id,
          refreshing: refreshView.refreshingSiteId == site.id,
          onTap: () => context.go(AppRoutes.siteDetailPath(site.id)),
          onTest: () => _test(site),
          onRefresh: () => _refreshSite(site),
          onToggleFavorite: () => ref.read(siteListProvider.notifier).toggleFavorite(site.id),
          onDelete: () => _confirmDelete(site),
        );
      },
    );
  }

  bool dataAsyncHasError(WidgetRef ref) => ref.read(profileDataProvider).hasError;
}

/// 站点列表项：图标 + 核心指标 + （可选）全部指标。
class _SiteTile extends StatelessWidget {
  const _SiteTile({
    required this.site,
    required this.stats,
    required this.masked,
    required this.expanded,
    required this.dataMissing,
    required this.testing,
    required this.refreshing,
    required this.onTap,
    required this.onTest,
    required this.onRefresh,
    required this.onToggleFavorite,
    required this.onDelete,
  });

  final PtSite site;
  final SiteStats? stats;
  final bool masked;
  final bool expanded;
  final bool dataMissing;
  final bool testing;
  final bool refreshing;
  final VoidCallback onTap;
  final VoidCallback onTest;
  final VoidCallback onRefresh;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;

  static StatusTone _tone(SiteHealth health) => switch (health) {
        SiteHealth.ok => StatusTone.ok,
        SiteHealth.warning => StatusTone.warning,
        SiteHealth.danger => StatusTone.danger,
        SiteHealth.unknown => StatusTone.neutral,
      };

  static StatusTone _refreshTone(SiteRefreshState state) => switch (state) {
        SiteRefreshState.refreshed => StatusTone.ok,
        SiteRefreshState.stale => StatusTone.info,
        SiteRefreshState.failed => StatusTone.danger,
        SiteRefreshState.notLoggedIn => StatusTone.warning,
        SiteRefreshState.unknown => StatusTone.neutral,
      };

  /// 打码直接替换字符，而不是只做视觉模糊：
  /// 模糊只影响渲染，读屏与文本选择仍会暴露原值，等于没打码。
  String _value(String text) => masked ? '•••' : text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SiteRefreshState refreshState = stats?.refreshState ?? SiteRefreshState.unknown;

    return SectionCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _SiteIcon(theme: theme, stats: stats, site: site),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            site.name,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (site.favorite) ...<Widget>[
                          const SizedBox(width: AppSpacing.xs),
                          const Icon(Icons.star, size: AppSizes.iconSm, color: AppColors.warning),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xxs),
                    Text(site.host, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xxs,
                      children: <Widget>[
                        StatusBadge(
                          label: refreshState.label,
                          tone: _refreshTone(refreshState),
                          compact: true,
                        ),
                        if (stats != null && stats!.careState != CareState.unknown)
                          StatusBadge(
                            label: stats!.careState.label,
                            tone: stats!.careState == CareState.healthy
                                ? StatusTone.ok
                                : (stats!.careState == CareState.attention
                                    ? StatusTone.warning
                                    : StatusTone.danger),
                            compact: true,
                          )
                        else
                          StatusBadge(
                            label: site.health.label,
                            tone: _tone(site.health),
                            compact: true,
                          ),
                        if (!site.credentialConfigured)
                          const StatusBadge(
                            label: '待录凭据',
                            tone: StatusTone.warning,
                            compact: true,
                          ),
                        if (!site.enabled)
                          const StatusBadge(label: '已停用', tone: StatusTone.neutral, compact: true),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (testing || refreshing)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  icon: const Icon(Icons.more_vert, size: AppSizes.iconMd),
                  onSelected: (String action) {
                    switch (action) {
                      case 'test':
                        onTest();
                      case 'refresh':
                        onRefresh();
                      case 'favorite':
                        onToggleFavorite();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(value: 'test', child: Text('测试连接')),
                    const PopupMenuItem<String>(value: 'refresh', child: Text('刷新该站数据')),
                    PopupMenuItem<String>(
                      value: 'favorite',
                      child: Text(site.favorite ? '取消收藏' : '收藏'),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem<String>(value: 'delete', child: Text('删除站点')),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (stats == null)
            Text(
              dataMissing ? '站点数据暂不可用（需 NAS 后端）' : '暂无该站数据',
              style: theme.textTheme.bodySmall,
            )
          else ...<Widget>[
            _metricsRow(stats!),
            if (expanded) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              _metricsGrid(theme, stats!),
            ],
            if (stats!.refreshMessage.isNotEmpty &&
                (refreshState == SiteRefreshState.failed ||
                    refreshState == SiteRefreshState.notLoggedIn)) ...<Widget>[
              const SizedBox(height: AppSpacing.xxs),
              Text(
                stats!.refreshMessage,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 核心指标（打码时只保留标签，数值一律遮蔽）。
  Widget _metricsRow(SiteStats data) {
    final List<(String, String)> items = <(String, String)>[
      ('上传', _value(formatBytes(data.uploadedBytes))),
      ('下载', _value(formatBytes(data.downloadedBytes))),
      ('分享率', _value(data.ratioLabel)),
      ('做种', _value('${data.seedingCount}')),
      ('时魔', _value(data.hourlyBonusLabel)),
      ('签到', _value(data.signInLabel)),
    ];
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xxs,
      children: <Widget>[
        for (final (String label, String value) in items) _Metric(label: label, value: value),
      ],
    );
  }

  /// 展开后的全部指标。
  Widget _metricsGrid(ThemeData theme, SiteStats data) {
    final List<(String, String)> items = <(String, String)>[
      ('魔力', _value(formatNumber(data.bonus))),
      ('下载中', _value('${data.leechingCount}')),
      ('连接数', _value('${data.connections}')),
      ('HR 情况', _value(data.hrLabel)),
      ('邮件数', _value('${data.unreadMessages}')),
      ('邀请数', _value('${data.invites}')),
      ('等级', _value(data.userClass.isEmpty ? '—' : data.userClass)),
      ('加入时间', _value(data.joinDate == null ? '—' : formatDate(data.joinDate!))),
    ];
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.cardBorder,
      ),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.sm,
        children: <Widget>[
          for (final (String label, String value) in items) _Metric(label: label, value: value),
        ],
      ),
    );
  }
}

/// 站点名首字（图标回退用）。
String _firstLetter(String name) {
  final String trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// 站点图标：后端给了地址就加载，否则用站点名首字生成。
class _SiteIcon extends StatelessWidget {
  const _SiteIcon({required this.theme, required this.stats, required this.site});

  final ThemeData theme;
  final SiteStats? stats;
  final PtSite site;

  @override
  Widget build(BuildContext context) {
    final String url = stats?.iconUrl ?? '';
    final Widget fallback = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
      ),
      child: Text(
        stats?.iconLetter ?? _firstLetter(site.name),
        style: theme.textTheme.titleSmall,
      ),
    );

    if (url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
      child: Image.network(
        url,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) => fallback,
      ),
    );
  }
}