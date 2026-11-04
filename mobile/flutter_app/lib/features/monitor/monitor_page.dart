import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/direct/direct_providers.dart';
import '../../core/models/monitor_dashboard.dart';
import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../sites/site_providers.dart';
import '../settings/status_providers.dart';

/// PT 监护室：站点病危 / 站庆 / 死亡 / 恢复公告（需求 6）。
///
/// 数据来源：**App 直连公开状态页**（默认 savept.icu，与控制台参考实现
/// 「Vue-PT 监护室」取的是同一份公开数据），因此不需要 NAS 后端即可用；
/// 实时抓取失败时展示最近一次成功快照并明确标注「缓存」。
/// 已部署 NAS 后端时，其后端巡检事件会作为补充段落显示。
class MonitorPage extends ConsumerStatefulWidget {
  const MonitorPage({super.key});

  @override
  ConsumerState<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends ConsumerState<MonitorPage> {
  final TextEditingController _query = TextEditingController();
  MonitorSiteState? _stateFilter;
  MonitorSiteScope? _scopeFilter;
  bool _anniversaryOnly = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.home);
    }
  }

  List<MonitorSiteCard> _visible(List<MonitorSiteCard> sites) {
    final String keyword = _query.text.trim().toLowerCase();
    return sites.where((MonitorSiteCard site) {
      final bool stateOk = _stateFilter == null || site.state == _stateFilter;
      final bool scopeOk = _scopeFilter == null || site.scope == _scopeFilter;
      final bool annivOk = !_anniversaryOnly || site.anniversaryCountdownDays == 0;
      final bool keywordOk = keyword.isEmpty ||
          site.name.toLowerCase().contains(keyword) ||
          site.host.toLowerCase().contains(keyword) ||
          site.searchKey.toLowerCase().contains(keyword);
      return stateOk && scopeOk && annivOk && keywordOk;
    }).toList(growable: false);
  }

  /// 本机站点清单里是否已有该站（按域名匹配，忽略 www. 与协议）。
  bool _isAdded(List<PtSite> localSites, MonitorSiteCard card) {
    final String key = card.identityKey;
    if (key.isEmpty) return false;
    for (final PtSite site in localSites) {
      if (site.host.toLowerCase().replaceFirst('www.', '') == key) return true;
    }
    return false;
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
    final AsyncValue<MonitorDashboard> dashboardAsync = ref.watch(monitorDashboardProvider);
    final List<PtSite> localSites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PT 监护室'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _leave(context)),
        actions: <Widget>[
          IconButton(
            tooltip: '历史事件',
            onPressed: () => _showHistory(context),
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.invalidate(monitorDashboardProvider),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: dashboardAsync.when(
        loading: () => const LoadingStateView(message: '正在读取监护室数据'),
        error: (Object error, StackTrace stackTrace) => ErrorStateView(
          title: '监护室数据获取失败',
          message: '$error',
          onRetry: () => ref.invalidate(monitorDashboardProvider),
        ),
        data: (MonitorDashboard dashboard) {
          if (dashboard.isEmpty) {
            return const EmptyStateView(
              icon: Icons.shield_outlined,
              title: '暂无监护数据',
              message: '站点病危、站庆与死亡公告会在这里按年份与分组展示。',
            );
          }
          final List<MonitorSiteCard> visible = _visible(dashboard.sites);
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: <Widget>[
              if (dashboard.fromCache)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: PartialResultBanner(
                    message: '实时抓取失败，以下为上次成功快照'
                        '${dashboard.fetchedAt == null ? '' : '（${_formatTime(dashboard.fetchedAt!)}）'}：'
                        '${dashboard.notice}',
                    onRetry: () => ref.invalidate(monitorDashboardProvider),
                  ),
                ),
              _totalsCard(theme, dashboard),
              if (dashboard.notices.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.lg),
                Text('公告', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                for (final MonitorNoticeGroup group in dashboard.notices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: _noticeCard(theme, group),
                  ),
              ],
              const SizedBox(height: AppSpacing.lg),
              Text('站点清单', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              _searchField(),
              _filterBar(),
              const SizedBox(height: AppSpacing.sm),
              if (visible.isEmpty)
                Text(
                  '没有符合筛选条件的站点，换个状态或清空搜索框。',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (final MonitorSiteCard card in visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: _siteCard(theme, card, _isAdded(localSites, card)),
                  ),
              if (nasConfigured) ...<Widget>[
                const SizedBox(height: AppSpacing.sm),
                _nasEventsSection(theme),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _totalsCard(ThemeData theme, MonitorDashboard dashboard) {
    final MonitorTotals totals = dashboard.totals;
    final List<(String, String, StatusTone)> metrics = <(String, String, StatusTone)>[
      ('床位', '${totals.total}', StatusTone.neutral),
      ('健康', '${totals.online}', StatusTone.ok),
      ('抢救', '${totals.down}', StatusTone.danger),
      ('死亡', '${totals.offline}', StatusTone.neutral),
      ('今日站庆', '${totals.anniversaryToday}', StatusTone.warning),
    ];
    return SectionCard(
      title: '监护概况',
      subtitle: dashboard.fetchedAt == null
          ? '数据源：${dashboard.sourceUrl}'
          : '数据源：${dashboard.sourceUrl} · 抓取于 ${_formatTime(dashboard.fetchedAt!)}',
      child: Wrap(
        spacing: AppSpacing.lg,
        runSpacing: AppSpacing.sm,
        children: <Widget>[
          for (final (String label, String value, StatusTone tone) in metrics)
            SizedBox(
              width: 66,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(label, style: theme.textTheme.labelSmall),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(
                    value,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: tone.resolve(theme.brightness),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _noticeCard(ThemeData theme, MonitorNoticeGroup group) {
    final (StatusTone tone, IconData icon) = switch (group.kind) {
      MonitorNoticeKind.rescue => (StatusTone.danger, Icons.monitor_heart_outlined),
      MonitorNoticeKind.recover => (StatusTone.ok, Icons.verified_outlined),
      MonitorNoticeKind.anniversary => (StatusTone.warning, Icons.celebration_outlined),
      MonitorNoticeKind.dead => (StatusTone.neutral, Icons.sentiment_dissatisfied_outlined),
      MonitorNoticeKind.unknown => (StatusTone.info, Icons.campaign_outlined),
    };
    return SectionCard(
      title: group.kind.label,
      subtitle: group.intro.isEmpty ? null : group.intro,
      trailing: StatusBadge(
        label: '${group.items.length} 条',
        tone: tone,
        icon: icon,
        compact: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final MonitorNoticeItem item in group.items)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xxs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  StatusBadge(label: item.name, tone: tone, compact: true),
                  if (item.tooltip.isNotEmpty)
                    Text(item.tooltip, style: theme.textTheme.bodySmall),
                  Text(
                    item.displayNote.isEmpty ? '—' : item.displayNote,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _searchField() => TextField(
        controller: _query,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: '搜索站点名称 / 域名',
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
      );

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xxs,
        children: <Widget>[
          FilterChip(
            label: const Text('全部状态'),
            selected: _stateFilter == null,
            onSelected: (bool _) => setState(() => _stateFilter = null),
          ),
          for (final MonitorSiteState state in <MonitorSiteState>[
            MonitorSiteState.online,
            MonitorSiteState.down,
            MonitorSiteState.offline,
          ])
            FilterChip(
              label: Text(state.label),
              selected: _stateFilter == state,
              onSelected: (bool value) =>
                  setState(() => _stateFilter = value ? state : null),
            ),
          const SizedBox(width: AppSpacing.xs),
          for (final MonitorSiteScope scope in <MonitorSiteScope>[
            MonitorSiteScope.internal,
            MonitorSiteScope.external,
          ])
            FilterChip(
              label: Text(scope.label),
              selected: _scopeFilter == scope,
              onSelected: (bool value) =>
                  setState(() => _scopeFilter = value ? scope : null),
            ),
          FilterChip(
            label: const Text('近期站庆'),
            selected: _anniversaryOnly,
            onSelected: (bool value) => setState(() => _anniversaryOnly = value),
          ),
        ],
      ),
    );
  }

  Widget _siteCard(ThemeData theme, MonitorSiteCard card, bool added) {
    final StatusTone tone = switch (card.state) {
      MonitorSiteState.online => StatusTone.ok,
      MonitorSiteState.down => StatusTone.danger,
      MonitorSiteState.offline => StatusTone.neutral,
      MonitorSiteState.unknown => StatusTone.neutral,
    };
    return SectionCard(
      onTap: () => _openSite(card.url),
      title: card.name,
      subtitle: card.scope.label == '未分类' ? card.host : '${card.scope.label} · ${card.host}',
      trailing: StatusBadge(label: card.state.label, tone: tone, compact: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xxs,
            children: <Widget>[
              if (card.anniversaryLabel.isNotEmpty)
                StatusBadge(
                  label: card.isTodayAnniversary ? '今天站庆' : card.anniversaryLabel,
                  tone: StatusTone.warning,
                  icon: Icons.celebration_outlined,
                  compact: true,
                ),
              if (card.aliveLabel.isNotEmpty)
                StatusBadge(label: card.aliveLabel, tone: StatusTone.info, compact: true),
              if (card.deadLabel.isNotEmpty)
                StatusBadge(label: card.deadLabel, tone: StatusTone.neutral, compact: true),
              StatusBadge(
                label: added ? '已在本机站点' : '未添加',
                tone: added ? StatusTone.ok : StatusTone.neutral,
                compact: true,
              ),
            ],
          ),
          if (card.periodLabel.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(card.periodLabel, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  /// NAS 后端巡检事件（仅在已配置后端时展示，作为监护室的补充来源）。
  Widget _nasEventsSection(ThemeData theme) {
    final AsyncValue<List<MonitorEvent>> eventsAsync = ref.watch(monitorEventsProvider);
    return eventsAsync.maybeWhen(
      data: (List<MonitorEvent> events) => events.isEmpty
          ? const SizedBox.shrink()
          : SectionCard(
              title: 'NAS 巡检事件',
              subtitle: '共 ${events.length} 条（来源：NAS 后端巡检）',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final MonitorEvent event in events.take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Wrap(
                        spacing: AppSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          StatusBadge(
                            label: event.siteName.isEmpty ? event.type.label : event.siteName,
                            tone: _severityTone(event.severity),
                            compact: true,
                          ),
                          Text(
                            event.title.isEmpty ? event.description : event.title,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
      orElse: () => const SizedBox.shrink(),
    );
  }

  Future<void> _showHistory(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      builder: (BuildContext sheetContext) => const _HistorySheet(),
    );
  }

  static StatusTone _severityTone(MonitorSeverity severity) => switch (severity) {
        MonitorSeverity.info => StatusTone.info,
        MonitorSeverity.warning => StatusTone.warning,
        MonitorSeverity.critical => StatusTone.danger,
      };

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

/// 历史事件弹窗：死亡 / 站庆两组，按页追加（页面上的「历史事件」入口同源）。
class _HistorySheet extends ConsumerStatefulWidget {
  const _HistorySheet();

  @override
  ConsumerState<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends ConsumerState<_HistorySheet> {
  MonitorHistoryKind _kind = MonitorHistoryKind.dead;
  int _page = 1;
  final List<MonitorHistoryEvent> _items = <MonitorHistoryEvent>[];
  bool _loading = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MonitorHistoryPage result =
          await ref.read(monitorHistoryProvider((kind: _kind, page: _page)).future);
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _page = result.nextPage ?? _page + 1;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _switchKind(MonitorHistoryKind kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _page = 1;
      _items.clear();
      _hasMore = true;
      _error = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('历史事件', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            children: <Widget>[
              for (final MonitorHistoryKind kind in MonitorHistoryKind.values)
                ChoiceChip(
                  label: Text(kind.label),
                  selected: _kind == kind,
                  onSelected: (bool _) => _switchKind(kind),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_error != null) Text(_error!, style: theme.textTheme.bodySmall),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _items.length + 1,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: AppSpacing.xs),
              itemBuilder: (BuildContext context, int index) {
                if (index == _items.length) {
                  if (_loading) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  }
                  if (!_hasMore) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                      child: Text('没有更多了', style: theme.textTheme.bodySmall),
                    );
                  }
                  return TextButton(onPressed: _load, child: const Text('加载更多'));
                }
                final MonitorHistoryEvent event = _items[index];
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 88,
                      child: Text(event.date, style: theme.textTheme.bodySmall),
                    ),
                    Expanded(
                      child: Text(
                        '${event.name}${event.label.isEmpty ? '' : ' · ${event.label}'}'
                        '${event.description.isEmpty ? '' : '（${event.description}）'}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}