import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/status_models.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../settings/status_providers.dart';

/// PT 监护室：站点病危、站庆等事件流（需求 6）。
///
/// 事件由 NAS 后端巡检生成（站点可达性、保号风险、站庆日历等），
/// 移动端只展示与跳转；严重事件可经推送通道提醒（需求 14）。
class MonitorPage extends ConsumerWidget {
  const MonitorPage({super.key});

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.home);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<MonitorEvent>> eventsAsync = ref.watch(monitorEventsProvider);
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PT 监护室'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _leave(context)),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.invalidate(monitorEventsProvider),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: !nasConfigured
          ? const EmptyStateView(
              icon: Icons.link_off,
              title: '尚未配置 NAS 服务地址',
              message: '监护巡检由 NAS 后端定时执行，请先完成服务配对。',
            )
          : eventsAsync.when(
              loading: () => const LoadingStateView(message: '正在读取监护事件'),
              error: (Object error, StackTrace stackTrace) => ErrorStateView(
                title: '事件获取失败',
                message: '$error',
                onRetry: () => ref.invalidate(monitorEventsProvider),
              ),
              data: (List<MonitorEvent> events) {
                if (events.isEmpty) {
                  return const EmptyStateView(
                    icon: Icons.shield_outlined,
                    title: '暂无监护事件',
                    message: '站点病危、站庆与风险巡检结果会在这里按时间倒序展示。',
                  );
                }
                final int critical = events
                    .where((MonitorEvent e) => e.severity == MonitorSeverity.critical)
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
                      title: '巡检概况',
                      subtitle: '共 ${events.length} 条事件',
                      child: Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: <Widget>[
                          StatusBadge(
                            label: '紧急 $critical',
                            tone: critical > 0 ? StatusTone.danger : StatusTone.neutral,
                            compact: true,
                          ),
                          const StatusBadge(
                            label: '来源：NAS 巡检',
                            tone: StatusTone.info,
                            compact: true,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    for (final MonitorEvent event in events)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: SectionCard(
                          title: event.title.isEmpty ? event.type.label : event.title,
                          subtitle: event.siteName.isEmpty
                              ? event.type.label
                              : '${event.siteName} · ${event.type.label}',
                          trailing: StatusBadge(
                            label: event.severity.label,
                            tone: _severityTone(event.severity),
                            icon: event.severity == MonitorSeverity.critical
                                ? Icons.warning_amber_outlined
                                : null,
                            compact: true,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (event.description.isNotEmpty)
                                Text(event.description, style: theme.textTheme.bodySmall),
                              if (event.occurredAt != null) ...<Widget>[
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  '发生时间 ${_formatTime(event.occurredAt!)}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                              if (event.link.isNotEmpty) ...<Widget>[
                                const SizedBox(height: AppSpacing.sm),
                                TextButton.icon(
                                  onPressed: () => context.go(AppRoutes.sites),
                                  icon: const Icon(Icons.open_in_new, size: AppSizes.iconSm),
                                  label: const Text('查看站点'),
                                ),
                              ],
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

  static StatusTone _severityTone(MonitorSeverity severity) => switch (severity) {
        MonitorSeverity.info => StatusTone.info,
        MonitorSeverity.warning => StatusTone.warning,
        MonitorSeverity.critical => StatusTone.danger,
      };

  static String _formatTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }
}