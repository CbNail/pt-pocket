import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/status_models.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../settings/status_providers.dart';

/// 我的 PT 数据：历程与数据统计（需求 2）。
class PtDataPage extends ConsumerWidget {
  const PtDataPage({super.key});

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<PtDataSnapshot> snapshotAsync = ref.watch(profileDataProvider);
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的数据'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _leave(context)),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.invalidate(profileDataProvider),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: !nasConfigured
          ? const EmptyStateView(
              icon: Icons.link_off,
              title: '尚未配置 NAS 服务地址',
              message: '个人数据由 NAS 后端从各站点采集，请先完成服务配对。',
            )
          : snapshotAsync.when(
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
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.sm,
                        AppSpacing.lg,
                        AppSpacing.xxl,
                      ),
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
                                  Expanded(
                                    child: _Metric(
                                      label: '总上传',
                                      value: formatBytes(snapshot.totalUploaded),
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: _Metric(
                                      label: '总下载',
                                      value: formatBytes(snapshot.totalDownloaded),
                                    ),
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
                                  Expanded(
                                    child: _Metric(
                                      label: '做种总数',
                                      value: '${snapshot.totalSeeding}',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.md),
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: _Metric(
                                      label: '今日上传',
                                      value: snapshot.todayUploadLabel,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: _Metric(
                                      label: '今日下载',
                                      value: snapshot.todayDownloadLabel,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.md),
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: _Metric(label: '今日签到', value: '${snapshot.signedInCount}/${snapshot.siteCount}'),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(child: _Metric(label: '魔力合计', value: '${snapshot.totalBonus}')),
                                ],
                              ),
                              if (!snapshot.hasTodayBaseline) ...<Widget>[
                                const SizedBox(height: AppSpacing.md),
                                Text(
                                  '今日增量 = 当日累计 − 前一自然日累计；缺少前一日的基线快照，'
                                  '所以暂不显示数值（后端补齐历史快照后自动恢复）。',
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
                                  _InfoRow(label: '魔力值', value: '${stats.bonus}'),
                                  _InfoRow(
                                    label: '加入时间',
                                    value: stats.joinDate == null
                                        ? '未知'
                                        : _formatDate(stats.joinDate!),
                                  ),
                                  _InfoRow(
                                    label: '今日签到',
                                    value: stats.signedInToday
                                        ? '已签到（连续 ${stats.consecutiveSignInDays} 天）'
                                        : '未签到',
                                  ),
                                  if (stats.classPlanLabel.isNotEmpty)
                                    _InfoRow(label: '等级路线', value: stats.classPlanLabel),
                                  _InfoRow(label: '保种契约', value: stats.contractLabel),
                                  if (stats.contractNote.isNotEmpty)
                                    _InfoRow(label: '契约说明', value: stats.contractNote),
                                  if ((stats.policy?.alternativesLabel ?? '').isNotEmpty)
                                    _InfoRow(label: '任选条件', value: stats.policy!.alternativesLabel),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
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