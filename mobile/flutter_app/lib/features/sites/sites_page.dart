import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/services/site_reachability_probe.dart';
import '../../core/storage/app_keys.dart';
import '../../core/storage/prefs_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../../shared/widgets/swipe_action_row.dart';
import '../settings/status_providers.dart';
import 'site_providers.dart';

/// 站点列表的展示密度。
enum SitesViewMode {
  detailed('详细'),
  compact('概述');

  const SitesViewMode(this.label);

  final String label;

  /// 缺省为「概述」：一屏能看更多站点；切到「详细」再看全部指标。
  static SitesViewMode fromName(String? value) =>
      value == SitesViewMode.detailed.name ? SitesViewMode.detailed : SitesViewMode.compact;
}

/// 站点页（需求 4）：站点数据面板。
///
/// 面板职责：
/// - 每站展示图标、状态与核心指标（上传 / 下载 / 分享率 / 做种 / 综合时魔 / 签到），
///   切到「详细」时补齐全部指标（魔力 / 下载中 / 连接数 / 邮件 / 邀请 / 等级 / 加入时间 / HR）；
/// - 顶部工具栏：打码开关、详细 / 概述切换、刷新全部、更多（PT 历程 / 监护室 / 签到 / 导入）；
/// - 卡片点击进入「站点资源」（从站点拉取的信息 + 该站资源列表）；
///   卡片右上角菜单与左滑都能到「编辑」「删除」；
/// - 支持按「已刷新 / 未刷新 / 失败 / 未登录」四态筛选。
///
/// 数据来源：NAS 后端可用时由后端下发；不可用时 App 直连站点用户页（`profileDataProvider`
/// 已封装该回退），并在本机保存每日采样。未取到的字段一律标注「未采集」，不显示 0 冒充。
class SitesPage extends ConsumerStatefulWidget {
  const SitesPage({super.key});

  @override
  ConsumerState<SitesPage> createState() => _SitesPageState();
}

class _SitesPageState extends ConsumerState<SitesPage> {
  final TextEditingController _query = TextEditingController();
  bool _favoriteFirst = false;

  /// 打码开关：屏蔽所有数值，方便在公共场合查看（落盘，重进页面保持）。
  bool _masked = false;

  /// 展示密度：详细 / 概述（落盘，重进页面保持）。
  SitesViewMode _viewMode = SitesViewMode.detailed;

  /// 当前左滑展开的站点 id（同一列表同时只允许展开一行）。
  String? _openId;

  final Set<SiteRefreshState> _refreshFilter = <SiteRefreshState>{};

  String? _testingId;

  PrefsStore get _prefs => ref.read(prefsStoreProvider);

  @override
  void initState() {
    super.initState();
    _masked = _prefs.getBool(PrefKeys.sitesMasked) ?? false;
    _viewMode = SitesViewMode.fromName(_prefs.getString(PrefKeys.sitesViewMode));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _toggleMasked() {
    setState(() => _masked = !_masked);
    _prefs.setBool(PrefKeys.sitesMasked, _masked);
  }

  void _toggleViewMode() {
    setState(() {
      _viewMode = _viewMode == SitesViewMode.detailed
          ? SitesViewMode.compact
          : SitesViewMode.detailed;
    });
    _prefs.setString(PrefKeys.sitesViewMode, _viewMode.name);
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
    setState(() => _openId = null);
    _snack('已删除「${site.name}」');
  }

  Future<void> _refreshAll() async {
    await ref.read(siteRefreshControllerProvider.notifier).refreshAll();
    if (!mounted) return;
    final SiteRefreshView after = ref.read(siteRefreshControllerProvider);
    _snack(after.error == null ? '已刷新站点数据（直连各站点用户页）' : '刷新失败：${after.error}');
  }

  Future<void> _refreshSite(PtSite site) async {
    await ref.read(siteRefreshControllerProvider.notifier).refreshSite(site.id);
    if (!mounted) return;
    final SiteRefreshView after = ref.read(siteRefreshControllerProvider);
    _snack(after.error == null ? '已刷新「${site.name}」数据' : '刷新失败：${after.error}');
  }

  void _openResources(PtSite site) => context.go(AppRoutes.siteResourcesPath(site.id));

  void _openEdit(PtSite site) {
    setState(() => _openId = null);
    context.go(AppRoutes.siteDetailPath(site.id));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
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
            onPressed: _toggleMasked,
            icon: Icon(_masked ? Icons.visibility_off : Icons.visibility),
          ),
          IconButton(
            tooltip: _viewMode == SitesViewMode.detailed ? '切换为概述展示' : '切换为详细展示',
            onPressed: _toggleViewMode,
            icon: Icon(
              _viewMode == SitesViewMode.detailed ? Icons.view_compact : Icons.grid_view,
            ),
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
          if (dataAsync.hasError)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
              child: PartialResultBanner(
                message: '站点数据汇总失败：${dataAsync.error}',
                onRetry: () => ref.invalidate(profileDataProvider),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '左滑卡片可编辑 / 删除；点卡片看该站资源',
                    style: theme.textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${_viewMode.label}展示${_masked ? ' · 已打码' : ''}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
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
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: AppSpacing.cardGap),
      itemBuilder: (BuildContext context, int index) {
        final PtSite site = visible[index];
        return SwipeActionRow(
          itemKey: site.id,
          openKey: _openId,
          onOpen: (String? key) => setState(() => _openId = key),
          actions: <SwipeActionButton>[
            SwipeActionButton(
              label: '编辑',
              icon: Icons.edit_outlined,
              onTap: () => _openEdit(site),
            ),
            SwipeActionButton(
              label: '删除',
              icon: Icons.delete_outline,
              background: theme.colorScheme.errorContainer,
              foreground: theme.colorScheme.onErrorContainer,
              onTap: () => _confirmDelete(site),
            ),
          ],
          child: _SiteTile(
            site: site,
            stats: stats[site.id],
            masked: _masked,
            viewMode: _viewMode,
            dataMissing: dataAsyncHasError(ref),
            testing: _testingId == site.id,
            refreshing: refreshView.refreshingSiteId == site.id,
            onTap: () => _openResources(site),
            onTest: () => _test(site),
            onRefresh: () => _refreshSite(site),
            onEdit: () => _openEdit(site),
            onToggleFavorite: () => ref.read(siteListProvider.notifier).toggleFavorite(site.id),
            onDelete: () => _confirmDelete(site),
          ),
        );
      },
    );
  }

  bool dataAsyncHasError(WidgetRef ref) => ref.read(profileDataProvider).hasError;
}

/// 站点列表项：图标 + 核心指标 + （详细模式）全部指标。
class _SiteTile extends StatelessWidget {
  const _SiteTile({
    required this.site,
    required this.stats,
    required this.masked,
    required this.viewMode,
    required this.dataMissing,
    required this.testing,
    required this.refreshing,
    required this.onTap,
    required this.onTest,
    required this.onRefresh,
    required this.onEdit,
    required this.onToggleFavorite,
    required this.onDelete,
  });

  final PtSite site;
  final SiteStats? stats;
  final bool masked;
  final SitesViewMode viewMode;
  final bool dataMissing;
  final bool testing;
  final bool refreshing;
  final VoidCallback onTap;
  final VoidCallback onTest;
  final VoidCallback onRefresh;
  final VoidCallback onEdit;
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

  static StatusTone _careTone(CareState state) => switch (state) {
        CareState.healthy => StatusTone.ok,
        CareState.attention => StatusTone.warning,
        CareState.atRisk => StatusTone.danger,
        CareState.unknown => StatusTone.neutral,
      };

  /// 打码直接替换字符，而不是只做视觉模糊：
  /// 模糊只影响渲染，读屏与文本选择仍会暴露原值，等于没打码。
  String _value(String text) => masked ? '•••' : text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SiteRefreshState refreshState = stats?.refreshState ?? SiteRefreshState.unknown;
    final bool detailed = viewMode == SitesViewMode.detailed;

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
                    const SizedBox(height: 2),
                    Text(
                      site.host,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
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
                            tone: _careTone(stats!.careState),
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
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.xs),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
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
                      case 'edit':
                        onEdit();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(value: 'edit', child: Text('编辑站点')),
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
          const SizedBox(height: AppSpacing.md),
          if (stats == null)
            Text(
              dataMissing ? '该站数据暂未取到（可点右上角刷新重试）' : '尚无该站数据',
              style: theme.textTheme.bodySmall,
            )
          else ...<Widget>[
            if (detailed) _metricsGrid(theme, stats!) else _metricsCompact(theme, stats!),
            if (stats!.refreshMessage.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.xs),
              Text(
                stats!.refreshMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: refreshState == SiteRefreshState.failed ||
                          refreshState == SiteRefreshState.notLoggedIn
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            Text(
              stats!.refreshedAt == null
                  ? '刷新时间：未采集'
                  : '刷新时间：${formatDateTime(stats!.refreshedAt!)}',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }

  /// 概述展示：三列对齐的核心指标 + 一行状态标签。
  Widget _metricsCompact(ThemeData theme, SiteStats data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _metricRow(theme, <(String, String)>[
          ('上传', _value(formatBytes(data.uploadedBytes))),
          ('下载', _value(formatBytes(data.downloadedBytes))),
          ('分享率', _value(data.ratioLabel)),
        ]),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xxs,
          children: <Widget>[
            StatusBadge(label: '做种 ${_value('${data.seedingCount}')}', tone: StatusTone.info, compact: true),
            StatusBadge(
              label: '时魔 ${_value(data.hourlyBonusLabel)}',
              tone: StatusTone.neutral,
              compact: true,
            ),
            StatusBadge(label: '签到 ${_value(data.signInLabel)}', tone: StatusTone.neutral, compact: true),
          ],
        ),
      ],
    );
  }

  /// 详细展示：三列对齐的完整指标网格（含今日增量、契约、等级等）。
  Widget _metricsGrid(ThemeData theme, SiteStats data) {
    final List<(String, String)> items = <(String, String)>[
      ('上传', _value(formatBytes(data.uploadedBytes))),
      ('下载', _value(formatBytes(data.downloadedBytes))),
      ('分享率', _value(data.ratioLabel)),
      ('今日上传', _value(data.todayUploadLabel)),
      ('今日下载', _value(data.todayDownloadLabel)),
      ('做种', _value('${data.seedingCount}')),
      ('下载中', _value('${data.leechingCount}')),
      ('魔力', _value(formatNumber(data.bonus))),
      ('时魔', _value(data.hourlyBonusLabel)),
      ('邀请数', _value('${data.invites}')),
      ('邮件数', _value('${data.unreadMessages}')),
      ('HR 情况', _value(data.hrLabel)),
      ('等级', _value(data.userClass.isEmpty ? '—' : data.userClass)),
      ('加入时间', _value(data.joinDate == null ? '—' : formatDate(data.joinDate!))),
      ('签到', _value(data.signInLabel)),
      ('契约', _value(data.contractLabel)),
      ('连接数', _value('${data.connections}')),
      ('保号', _value(data.policy?.summary ?? '—')),
    ];
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < items.length; i += 3) {
      final List<(String, String)> slice = items.sublist(i, (i + 3).clamp(0, items.length));
      rows.add(_metricRow(theme, slice));
      if (i + 3 < items.length) rows.add(const SizedBox(height: AppSpacing.sm));
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ...rows,
          if (data.classPlanLabel.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.sm),
            Text(data.classPlanLabel, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  /// 三列对齐的指标行：列宽相等、标签在上数值在下，换行也能对齐。
  Widget _metricRow(ThemeData theme, List<(String, String)> items) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < 3; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: AppSpacing.md),
          Expanded(
            child: i < items.length
                ? _Metric(label: items[i].$1, value: items[i].$2)
                : const SizedBox.shrink(),
          ),
        ],
      ],
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
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 站点图标：直连取到图标地址就加载，否则用站点名首字生成。
class _SiteIcon extends StatelessWidget {
  const _SiteIcon({required this.theme, required this.stats, required this.site});

  final ThemeData theme;
  final SiteStats? stats;
  final PtSite site;

  @override
  Widget build(BuildContext context) {
    final String url = stats?.iconUrl ?? '';
    final Widget fallback = Container(
      width: 42,
      height: 42,
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
        width: 42,
        height: 42,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stackTrace) => fallback,
      ),
    );
  }
}