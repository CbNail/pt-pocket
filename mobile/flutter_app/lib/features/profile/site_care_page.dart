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

/// 各 PT 站养老（保号）进度（需求 5）。
///
/// 保号要求由服务端按站点规则解析；本页展示要求摘要与当前进度，
/// 进度不足的站点会被标为「需关注 / 有掉级风险」。
class SiteCarePage extends ConsumerWidget {
  const SiteCarePage({super.key});

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
        title: const Text('养老进度'),
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
              message: '保号进度需要服务端读取站点个人页，请先完成服务配对。',
            )
          : snapshotAsync.when(
              loading: () => const LoadingStateView(message: '正在计算保号进度'),
              error: (Object error, StackTrace stackTrace) => ErrorStateView(
                title: '进度获取失败',
                message: '$error',
                onRetry: () => ref.invalidate(profileDataProvider),
              ),
              data: (PtDataSnapshot snapshot) {
                if (snapshot.sites.isEmpty) {
                  return const EmptyStateView(
                    icon: Icons.savings_outlined,
                    title: '还没有可统计的站点',
                    message: '添加并启用站点后，这里会按站点展示保号要求与进度。',
                  );
                }
                final int atRisk = snapshot.sites
                    .where((SiteStats s) => s.careState == CareState.atRisk)
                    .length;
                final int attention = snapshot.sites
                    .where((SiteStats s) => s.careState == CareState.attention)
                    .length;

                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.sm,
                    AppSpacing.lg,
                    AppSpacing.xxl,
                  ),
                  children: <Widget>[
                    SectionCard(
                      title: '总体情况',
                      subtitle: '进度口径来自站点保号规则',
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: StatusBadge(
                              label: '有掉级风险 $atRisk',
                              tone: atRisk > 0 ? StatusTone.danger : StatusTone.neutral,
                              compact: true,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: StatusBadge(
                              label: '需关注 $attention',
                              tone: attention > 0 ? StatusTone.warning : StatusTone.neutral,
                              compact: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    for (final SiteStats stats in snapshot.sites)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: SectionCard(
                          title: stats.siteName.isEmpty ? stats.siteId : stats.siteName,
                          subtitle: stats.policy?.summary ??
                              '站点未提供明确的保号要求',
                          trailing: StatusBadge(
                            label: stats.careState.label,
                            tone: _careTone(stats.careState),
                            compact: true,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              ClipRRect(
                                borderRadius: BorderRadius.circular(AppRadius.chip),
                                child: LinearProgressIndicator(
                                  value: stats.careProgress.clamp(0, 1),
                                  minHeight: 6,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                '保号进度 ${formatPercent(stats.careProgress)}',
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: AppSpacing.xs,
                                runSpacing: AppSpacing.xxs,
                                children: <Widget>[
                                  StatusBadge(
                                    label: '分享率 ${stats.ratioLabel}',
                                    tone: StatusTone.info,
                                    compact: true,
                                  ),
                                  StatusBadge(
                                    label: '做种 ${stats.seedingCount}',
                                    tone: StatusTone.info,
                                    compact: true,
                                  ),
                                  StatusBadge(
                                    label: stats.signedInToday ? '今日已签到' : '今日未签到',
                                    tone: stats.signedInToday
                                        ? StatusTone.ok
                                        : StatusTone.warning,
                                    compact: true,
                                  ),
                                ],
                              ),
                              if (stats.classPlanLabel.isNotEmpty) ...<Widget>[
                                const SizedBox(height: AppSpacing.xs),
                                Text(stats.classPlanLabel, style: theme.textTheme.bodySmall),
                              ],
                              if ((stats.policy?.alternativesLabel ?? '').isNotEmpty) ...<Widget>[
                                const SizedBox(height: AppSpacing.xxs),
                                Text(stats.policy!.alternativesLabel, style: theme.textTheme.bodySmall),
                              ],
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: AppSpacing.xs,
                                runSpacing: AppSpacing.xxs,
                                children: <Widget>[
                                  // 保种契约（H&R）达成情况：与保号进度是两套口径，分开呈现。
                                  StatusBadge(
                                    label: stats.contractMet == null
                                        ? '契约 数据未提供'
                                        : '契约 ${stats.contractLabel}',
                                    tone: stats.contractMet == null
                                        ? StatusTone.neutral
                                        : (stats.contractMet! ? StatusTone.ok : StatusTone.danger),
                                    compact: true,
                                  ),
                                  StatusBadge(
                                    label: 'HR ${stats.hrLabel}',
                                    tone: stats.hrCount > 0 ? StatusTone.warning : StatusTone.neutral,
                                    compact: true,
                                  ),
                                ],
                              ),
                              if (stats.contractNote.isNotEmpty) ...<Widget>[
                                const SizedBox(height: AppSpacing.xxs),
                                Text(stats.contractNote, style: theme.textTheme.bodySmall),
                              ],
                              const SizedBox(height: AppSpacing.sm),
                              FilledButton.tonalIcon(
                                onPressed: () => context.go(AppRoutes.settingsSignInPath),
                                icon: const Icon(Icons.event_available, size: AppSizes.iconSm),
                                label: const Text('去签到中心'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }

  static StatusTone _careTone(CareState state) => switch (state) {
        CareState.healthy => StatusTone.ok,
        CareState.attention => StatusTone.warning,
        CareState.atRisk => StatusTone.danger,
        CareState.unknown => StatusTone.neutral,
      };
}