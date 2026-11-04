import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/direct/stats_history_store.dart';
import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../sites/site_providers.dart';
import '../settings/status_providers.dart';

/// 我的 PT 数据：数据总览 + 时间轴（需求 2）。
///
/// 数据来源：App 直连各站点用户页采集（[profileDataProvider]）与本机保存的每日采样
/// （[StatsHistoryStore]）。时间轴口径与参考实现（PT-depiler 的「我的数据 · 时间轴」）一致：
/// 每个自然日一条记录，展示当日增量与当日累计；缺前一自然日基线时明确写「基线不足」。
class PtDataPage extends ConsumerStatefulWidget {
  const PtDataPage({super.key});

  @override
  ConsumerState<PtDataPage> createState() => _PtDataPageState();
}

enum _DataView {
  overview('数据总览'),
  timeline('时间轴');

  const _DataView(this.label);

  final String label;
}

class _PtDataPageState extends ConsumerState<PtDataPage> {
  _DataView _view = _DataView.overview;

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<PtDataSnapshot> snapshotAsync = ref.watch(profileDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的数据'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _leave(context)),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.read(siteRefreshControllerProvider.notifier).refreshAll(),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<_DataView>(
                showSelectedIcon: false,
                segments: <ButtonSegment<_DataView>>[
                  for (final _DataView view in _DataView.values)
                    ButtonSegment<_DataView>(value: view, label: Text(view.label)),
                ],
                selected: <_DataView>{_view},
                onSelectionChanged: (Set<_DataView> selection) =>
                    setState(() => _view = selection.first),
              ),
            ),
          ),
          Expanded(
            child: snapshotAsync.when(
              loading: () => const LoadingStateView(message: '正在汇总各站点数据'),
              error: (Object error, StackTrace stackTrace) => ErrorStateView(
                title: '数据获取失败',
                message: '$error',
                onRetry: () => ref.invalidate(profileDataProvider),
              ),
              data: (PtDataSnapshot snapshot) => snapshot.sites.isEmpty
                  ? const EmptyStateView(
                      icon: Icons.insights_outlined,
                      title: '还没有可统计的站点',
                      message: '先在站点模块添加并启用站点，个人数据会按站点汇总。',
                    )
                  : (_view == _DataView.overview
                      ? _overviewView(theme, snapshot)
                      : _timelineView(theme, snapshot)),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 数据总览

  Widget _overviewView(ThemeData theme, PtDataSnapshot snapshot) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
      children: <Widget>[
        SectionCard(
          title: '总体统计',
          subtitle: snapshot.generatedAt == null
              ? '${snapshot.siteCount} 个站点'
              : '${snapshot.siteCount} 个站点 · 更新于 ${_formatTime(snapshot.generatedAt!)}',
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: _Metric(label: '总上传', value: formatBytes(snapshot.totalUploaded))),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: _Metric(label: '总下载', value: formatBytes(snapshot.totalDownloaded)),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _Metric(
                      label: '总体分享率',
                      value: snapshot.overallRatio == null
                          ? '—'
                          : snapshot.overallRatio!.toStringAsFixed(2),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: _Metric(label: '做种总数', value: '${snapshot.totalSeeding}')),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: <Widget>[
                  Expanded(child: _Metric(label: '今日上传', value: snapshot.todayUploadLabel)),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: _Metric(label: '今日下载', value: snapshot.todayDownloadLabel)),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _Metric(
                      label: '今日签到',
                      value: snapshot.signInKnownCount == 0
                          ? '未采集'
                          : '${snapshot.signedInCount}/${snapshot.signInKnownCount}',
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: _Metric(label: '魔力合计', value: formatNumber(snapshot.totalBonus))),
                ],
              ),
              if (!snapshot.hasTodayBaseline) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                Text(
                  '今日增量 = 当日累计 − 前一自然日累计；本机还没有前一日的采样基线，'
                  '所以暂不显示数值（保持 App 使用一天后自动恢复）。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        if (snapshot.notice.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.md),
          Text(snapshot.notice, style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: AppSpacing.lg),
        Text('各站点明细', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        for (final SiteStats stats in snapshot.sites)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: SectionCard(
              title: stats.siteName.isEmpty ? stats.siteId : stats.siteName,
              subtitle: stats.username.isEmpty
                  ? stats.userClass
                  : '${stats.username}${stats.userClass.isEmpty ? '' : ' · ${stats.userClass}'}',
              trailing: StatusBadge(
                label: stats.careState.label,
                tone: _careTone(stats.careState),
                compact: true,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _InfoRow(label: '上传', value: formatBytes(stats.uploadedBytes)),
                  _InfoRow(label: '下载', value: formatBytes(stats.downloadedBytes)),
                  _InfoRow(label: '今日上传', value: stats.todayUploadLabel),
                  _InfoRow(label: '今日下载', value: stats.todayDownloadLabel),
                  _InfoRow(label: '分享率', value: stats.ratioLabel),
                  _InfoRow(label: '做种/下载中', value: '${stats.seedingCount} / ${stats.leechingCount}'),
                  _InfoRow(label: '魔力值', value: formatNumber(stats.bonus)),
                  _InfoRow(label: '综合时魔', value: _hourlyLabel(stats)),
                  _InfoRow(
                    label: '加入时间',
                    value: stats.joinDate == null ? '未知' : _formatDate(stats.joinDate!),
                  ),
                  _InfoRow(label: '签到', value: stats.signInStatusLabel),
                  if (stats.classPlanLabel.isNotEmpty)
                    _InfoRow(label: '等级路线', value: stats.classPlanLabel),
                  _InfoRow(label: '保种契约', value: stats.contractLabel),
                  if (stats.contractNote.isNotEmpty)
                    _InfoRow(label: '契约说明', value: stats.contractNote),
                  if ((stats.policy?.alternativesLabel ?? '').isNotEmpty)
                    _InfoRow(label: '任选条件', value: stats.policy!.alternativesLabel),
                  if (stats.refreshMessage.isNotEmpty &&
                      stats.refreshState != SiteRefreshState.refreshed)
                    _InfoRow(label: '说明', value: stats.refreshMessage),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 综合时魔是本地估算值（近 12 小时内两次采样差值），必须标注来源。
  static String _hourlyLabel(SiteStats stats) {
    if (stats.hourlyBonus <= 0) return '未采集（需两次采样）';
    return '${stats.hourlyBonusLabel} · 本地估算';
  }

  // ---------------------------------------------------------------- 时间轴

  Widget _timelineView(ThemeData theme, PtDataSnapshot snapshot) {
    final List<PtSite> sites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];
    final Map<String, PtSite> byId = <String, PtSite>{
      for (final PtSite site in sites) site.id: site,
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
      children: <Widget>[
        Text(
          '时间轴按自然日记录每日上传 / 下载增量与当日累计，数据来自本机采样（最多保留 400 条）。'
          '缺前一自然日基线的那一天显示「基线不足」，不用 0 冒充。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        for (final SiteStats stats in snapshot.sites)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: _SiteTimelineCard(
              siteName: stats.siteName.isEmpty
                  ? (byId[stats.siteId]?.name ?? stats.siteId)
                  : stats.siteName,
              siteId: stats.siteId,
            ),
          ),
      ],
    );
  }

  static StatusTone _careTone(CareState state) => switch (state) {
        CareState.healthy => StatusTone.ok,
        CareState.attention => StatusTone.warning,
        CareState.atRisk => StatusTone.danger,
        CareState.unknown => StatusTone.neutral,
      };

  static String _formatTime(DateTime time) =>
      '${_formatDate(time)} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static String _formatDate(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }
}

/// 单站时间轴卡片：按自然日列出增量与累计。
class _SiteTimelineCard extends ConsumerWidget {
  const _SiteTimelineCard({required this.siteId, required this.siteName});

  final String siteId;
  final String siteName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final List<TrendPoint> points = ref.watch(
      siteTrendProvider(siteId),
    );
    final List<TrendPoint> recent = points.take(14).toList(growable: false);

    return SectionCard(
      title: siteName,
      subtitle: points.isEmpty
          ? '还没有采样记录'
          : '共 ${points.length} 天记录 · 显示最近 ${recent.length} 天',
      child: points.isEmpty
          ? Text(
              '刷新该站数据后会开始记录每日采样，第二天起就能看到增量。',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    SizedBox(width: 92, child: Text('日期', style: theme.textTheme.labelSmall)),
                    Expanded(child: Text('上传增量', style: theme.textTheme.labelSmall)),
                    Expanded(child: Text('下载增量', style: theme.textTheme.labelSmall)),
                    Text('魔力', style: theme.textTheme.labelSmall),
                  ],
                ),
                const SizedBox(height: AppSpacing.xxs),
                for (final TrendPoint point in recent)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 92,
                          child: Text(point.date, style: theme.textTheme.bodySmall),
                        ),
                        Expanded(
                          child: Text(
                            point.hasBaseline ? formatBytes(point.uploadedDelta!) : '基线不足',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: point.hasBaseline
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            point.hasBaseline ? formatBytes(point.downloadedDelta!) : '基线不足',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: point.hasBaseline
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(formatNumber(point.bonus), style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
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
      children: <Widget>[
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.xxs),
        Text(value, style: theme.textTheme.titleMedium),
      ],
    );
  }
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
          SizedBox(width: 92, child: Text(label, style: theme.textTheme.bodySmall)),
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