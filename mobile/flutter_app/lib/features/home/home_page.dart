import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/major_site.dart';
import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/format.dart';
import '../../shared/widgets/link_badge.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/site_progress_matrix.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../downloaders/downloader_providers.dart';
import '../settings/status_providers.dart';
import '../sites/site_providers.dart';

/// 首页：站点概览、监护提醒、12 大站点收集进度与常用入口（规格书 §6.4、需求 11）。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;

    final List<MajorSiteSlot> slots =
        ref.watch(majorSiteSlotsProvider).valueOrNull ?? MajorSiteSlot.defaults();
    final List<PtSite> sites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];
    final int downloaderCount = ref.watch(downloaderListProvider).valueOrNull?.length ?? 0;
    final List<MonitorEvent> events =
        ref.watch(monitorEventsProvider).valueOrNull ?? const <MonitorEvent>[];
    final PtDataSnapshot? profile = ref.watch(profileDataProvider).valueOrNull;
    final SignInAutoConfig auto = ref.watch(signInAutoProvider);

    final int configuredSlots = slots.where((MajorSiteSlot s) => s.isConfigured).length;
    final int criticalEvents =
        events.where((MonitorEvent e) => e.severity == MonitorSeverity.critical).length;
    final List<MajorSiteProgress> matrix = slots
        .map((MajorSiteSlot slot) => MajorSiteProgress(
              slot: slot.slot - 1,
              siteId: slot.siteId.isEmpty ? null : slot.siteId,
              name: slot.name.isEmpty ? null : slot.name,
              isCollected: _isCollected(slot, sites),
              progress: _slotProgress(slot, profile),
            ))
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('PT Pocket'),
        actions: <Widget>[
          LinkBadge(onTap: () => context.go(AppRoutes.settings)),
          IconButton(
            tooltip: 'PT 监护室',
            onPressed: () => context.go(AppRoutes.settingsMonitorPath),
            icon: const Icon(Icons.notifications_none),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          if (!nasConfigured)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: PartialResultBanner(
                message: '尚未配置 NAS 服务地址，先在「我的 · 连接与服务」完成配对。',
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: OverviewStatTile(
                  label: '已添加站点',
                  value: '${sites.length}',
                  tone: sites.isEmpty ? StatusTone.neutral : StatusTone.ok,
                  icon: Icons.dns_outlined,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: OverviewStatTile(
                  label: '监护事件',
                  value: events.isEmpty ? '—' : '${events.length}',
                  tone: criticalEvents > 0
                      ? StatusTone.danger
                      : (events.isEmpty ? StatusTone.neutral : StatusTone.warning),
                  icon: Icons.shield_outlined,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: OverviewStatTile(
                  label: '下载器',
                  value: downloaderCount == 0 ? '—' : '$downloaderCount',
                  tone: downloaderCount == 0 ? StatusTone.neutral : StatusTone.info,
                  icon: Icons.download_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '12 大站点收集进度',
            subtitle: '已配置 $configuredSlots / ${slots.length}（可在「我的 · 12 大站点」配置清单）',
            trailing: TextButton(
              onPressed: () => context.go(AppRoutes.settingsMajorSitesPath),
              child: const Text('配置'),
            ),
            child: SiteProgressMatrix(
              sites: matrix,
              onTapSlot: (_) => context.go(AppRoutes.settingsMajorSitesPath),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '风险 / 站庆提醒',
            subtitle: '来自 PT 监护室的事件流',
            trailing: TextButton(
              onPressed: () => context.go(AppRoutes.settingsMonitorPath),
              child: const Text('全部'),
            ),
            child: events.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                    child: EmptyStateView(
                      icon: Icons.shield_outlined,
                      title: '暂无待处理事件',
                      message: '站点病危、站庆与风险来源会在 NAS 完成巡检后在此展示。',
                    ),
                  )
                : Column(
                    children: <Widget>[
                      for (final MonitorEvent event in events.take(3))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                          child: Row(
                            children: <Widget>[
                              StatusBadge(
                                label: event.severity.label,
                                tone: _severityTone(event.severity),
                                compact: true,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      event.title.isEmpty ? event.type.label : event.title,
                                      style: theme.textTheme.bodyMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (event.siteName.isNotEmpty)
                                      Text(event.siteName, style: theme.textTheme.bodySmall),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '常用入口',
            subtitle: '签到、数据、养老进度与监护室',
            child: Column(
              children: <Widget>[
                _QuickRow(
                  icon: Icons.event_available,
                  title: '一键签到',
                  subtitle: auto.enabled ? '自动补签 ${auto.label}' : '未开启自动补签',
                  onTap: () => context.go(AppRoutes.settingsSignInPath),
                ),
                _QuickRow(
                  icon: Icons.insights_outlined,
                  title: '我的数据',
                  subtitle: profile == null
                      ? '未采集'
                      : '${profile.siteCount} 个站点 · 分享率 ${profile.overallRatio == null ? '—' : profile.overallRatio!.toStringAsFixed(2)}',
                  onTap: () => context.go(AppRoutes.settingsPtDataPath),
                ),
                _QuickRow(
                  icon: Icons.savings_outlined,
                  title: '养老进度',
                  subtitle: profile == null
                      ? '未采集'
                      : '有风险 '
                          '${profile.sites.where((SiteStats s) => s.careState == CareState.atRisk).length} 个站点',
                  onTap: () => context.go(AppRoutes.settingsSiteCarePath),
                ),
                _QuickRow(
                  icon: Icons.shield_outlined,
                  title: 'PT 监护室',
                  subtitle: events.isEmpty ? '暂无事件' : '${events.length} 条事件',
                  onTap: () => context.go(AppRoutes.settingsMonitorPath),
                ),
                _QuickRow(
                  icon: Icons.upload_outlined,
                  title: '推送通道',
                  subtitle: ref.watch(notifySettingsProvider).summary,
                  onTap: () => context.go(AppRoutes.settingsNotifyPath),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 槽位是否已收集：已关联站点且该站点仍存在（或按名称匹配到站点）。
  static bool _isCollected(MajorSiteSlot slot, List<PtSite> sites) {
    if (!slot.isConfigured) return false;
    if (slot.siteId.isEmpty) {
      return sites.any((PtSite s) => s.name == slot.name);
    }
    return sites.any((PtSite s) => s.id == slot.siteId);
  }

  /// 槽位进度：已采集到个人数据时用保号进度，否则无指标。
  static double? _slotProgress(MajorSiteSlot slot, PtDataSnapshot? profile) {
    if (profile == null || slot.siteId.isEmpty) return null;
    for (final SiteStats stats in profile.sites) {
      if (stats.siteId == slot.siteId) {
        return stats.careProgress > 0 ? stats.careProgress : null;
      }
    }
    return null;
  }

  static StatusTone _severityTone(MonitorSeverity severity) => switch (severity) {
        MonitorSeverity.info => StatusTone.info,
        MonitorSeverity.warning => StatusTone.warning,
        MonitorSeverity.critical => StatusTone.danger,
      };
}

class _QuickRow extends StatelessWidget {
  const _QuickRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: <Widget>[
            Icon(icon, size: AppSizes.iconMd, color: theme.colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: AppSpacing.xxs),
                  Text(subtitle, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: AppSizes.iconMd, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 保持格式化工具在本页可用（大文件体积与速率展示口径统一）。
String formatBytesForHome(int bytes) => formatBytes(bytes);