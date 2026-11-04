import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/status_models.dart';
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
/// 数据来源：App 直连站点用户页（[profileDataProvider]）＋内置等级路线规则
/// （[CareRules]：注册时长 + 上传量 + 分享率，NexusPHP 默认口径）。
/// 页面把「还差多少」逐条写出来（还差 N 天 / 还差 X 上传 / 分享率需 ≥ N），
/// 并明确标注规则是默认口径估算，避免让人误以为是站点官方规则。
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('养老进度'),
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
      body: snapshotAsync.when(
        loading: () => const LoadingStateView(message: '正在计算养老进度'),
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
              message: '添加并启用站点后，这里会按站点展示等级路线与保号进度。',
            );
          }
          final int atRisk =
              snapshot.sites.where((SiteStats s) => s.careState == CareState.atRisk).length;
          final int attention =
              snapshot.sites.where((SiteStats s) => s.careState == CareState.attention).length;
          final int unknown =
              snapshot.sites.where((SiteStats s) => s.careState == CareState.unknown).length;

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
                subtitle: '进度按内置等级规则（NexusPHP 默认口径）估算',
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: <Widget>[
                    StatusBadge(
                      label: '有掉级风险 $atRisk',
                      tone: atRisk > 0 ? StatusTone.danger : StatusTone.neutral,
                      compact: true,
                    ),
                    StatusBadge(
                      label: '需关注 $attention',
                      tone: attention > 0 ? StatusTone.warning : StatusTone.neutral,
                      compact: true,
                    ),
                    if (unknown > 0)
                      StatusBadge(
                        label: '数据不足 $unknown',
                        tone: StatusTone.neutral,
                        compact: true,
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
                    subtitle: stats.policy?.summary ?? '站点未提供明确的保号要求',
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
                              label: stats.signInStatusLabel,
                              tone: stats.signInKnown
                                  ? (stats.signedInToday ? StatusTone.ok : StatusTone.warning)
                                  : StatusTone.neutral,
                              compact: true,
                            ),
                            StatusBadge(
                              label: stats.hourlyBonus > 0
                                  ? '时魔 ${stats.hourlyBonusLabel}（估算）'
                                  : '时魔 未采集',
                              tone: StatusTone.neutral,
                              compact: true,
                            ),
                          ],
                        ),
                        if (stats.classPlanLabel.isNotEmpty) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          Text(stats.classPlanLabel, style: theme.textTheme.bodyMedium),
                        ],
                        if (stats.levelSteps.isNotEmpty) ...<Widget>[
                          const SizedBox(height: AppSpacing.sm),
                          _LevelLadder(steps: stats.levelSteps),
                        ],
                        if ((stats.policy?.alternativesLabel ?? '').isNotEmpty) ...<Widget>[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            stats.policy!.alternativesLabel,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                        if (stats.promotionNote.isNotEmpty) ...<Widget>[
                          const SizedBox(height: AppSpacing.xxs),
                          Text(stats.promotionNote, style: theme.textTheme.bodySmall),
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
                        if (stats.refreshMessage.isNotEmpty &&
                            stats.refreshState != SiteRefreshState.refreshed) ...<Widget>[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            stats.refreshMessage,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error),
                          ),
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

/// 等级路线：逐级列出门槛、是否达成，未达成的写清「还差多少」。
class _LevelLadder extends StatelessWidget {
  const _LevelLadder({required this.steps});

  final List<LevelStep> steps;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: AppRadius.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('等级路线（默认口径）', style: theme.textTheme.labelSmall),
          const SizedBox(height: AppSpacing.xxs),
          for (final LevelStep step in steps)
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
                        Text(
                          step.name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: step.achieved ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
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
}