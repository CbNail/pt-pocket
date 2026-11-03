import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/app_config.dart';
import '../../core/models/moviepilot.dart';
import '../../core/models/notify_settings.dart';
import '../../core/models/proxy_settings.dart';
import '../../core/models/status_models.dart';
import '../../core/network/endpoint_resolver.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/link_badge.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import '../downloaders/downloader_providers.dart';
import '../search/search_providers.dart';
import 'status_providers.dart';

/// 「我的」页：连接与服务、下载与搜索、数据与状态、外观、代理与推送、关于
/// （规格书 §4.1 / §5.5）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  static const String _unset = '未设置';

  static String _urlText(Uri? uri) => uri == null ? _unset : uri.toString();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EndpointProfile profile = ref.watch(endpointProfileProvider);
    final ProxySettings proxy = ref.watch(proxySettingsProvider);
    final ThemeMode mode = ref.watch(themeModeProvider);
    final int downloaderCount = ref.watch(downloaderListProvider).valueOrNull?.length ?? 0;
    final List<MpInstance> mps = ref.watch(mpListProvider).valueOrNull ?? const <MpInstance>[];
    final int enhanceCount = ref.watch(searchEnhanceInstanceIdsProvider).length;
    final List<MajorSiteSlot> slots =
        ref.watch(majorSiteSlotsProvider).valueOrNull ?? MajorSiteSlot.defaults();
    final int configuredSlots = slots.where((MajorSiteSlot s) => s.isConfigured).length;
    final NotifySettings notify = ref.watch(notifySettingsProvider);
    final SignInAutoConfig auto = ref.watch(signInAutoProvider);
    final PtDataSnapshot? snapshot = ref.watch(profileDataProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        actions: <Widget>[
          LinkBadge(onTap: () => context.go(AppRoutes.settings)),
          const SizedBox(width: AppSpacing.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '连接与服务',
            subtitle: '外网入口经 lucky 反代；自动模式下内网优先、失败回退外网',
            trailing: TextButton(
              onPressed: () => context.go(AppRoutes.settingsConnectionPath),
              child: const Text('配置'),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _SettingRow(
                  icon: Icons.swap_horiz,
                  label: '链路模式',
                  value: profile.mode.label,
                  muted: false,
                ),
                _SettingRow(
                  icon: Icons.lan_outlined,
                  label: '内网地址',
                  value: _urlText(profile.lanBaseUrl),
                  muted: profile.lanBaseUrl == null,
                ),
                _SettingRow(
                  icon: Icons.public,
                  label: '外网地址',
                  value: _urlText(profile.wanBaseUrl),
                  muted: profile.wanBaseUrl == null,
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: <Widget>[
                    StatusBadge(
                      label: profile.isConfigured ? '已配置' : '未配置',
                      tone: profile.isConfigured ? StatusTone.ok : StatusTone.warning,
                      compact: true,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '自动切换：回到家网自动改用内网，外出自动回退外网',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '下载与搜索',
            subtitle: '多下载器与 MoviePilot 实例（可用于搜索增强）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _SettingRow(
                  icon: Icons.download_outlined,
                  label: '下载器',
                  value: downloaderCount == 0 ? '未添加' : '$downloaderCount 个',
                  muted: downloaderCount == 0,
                  onTap: () => context.go(AppRoutes.downloaders),
                ),
                _SettingRow(
                  icon: Icons.auto_awesome,
                  label: 'MoviePilot',
                  value: mps.isEmpty ? '未添加' : '${mps.length} 个实例 · 增强 $enhanceCount',
                  muted: mps.isEmpty,
                  onTap: () => context.go(AppRoutes.settingsMoviePilotPath),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '数据与状态',
            subtitle: '我的数据、养老进度、签到与监护室',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _SettingRow(
                  icon: Icons.insights_outlined,
                  label: '我的数据',
                  value: snapshot == null ? '未采集' : '${snapshot.siteCount} 个站点',
                  muted: snapshot == null,
                  onTap: () => context.go(AppRoutes.settingsPtDataPath),
                ),
                _SettingRow(
                  icon: Icons.savings_outlined,
                  label: '养老进度',
                  value: snapshot == null
                      ? '未采集'
                      : '风险 '
                          '${snapshot.sites.where((SiteStats s) => s.careState == CareState.atRisk).length} 个',
                  muted: snapshot == null,
                  onTap: () => context.go(AppRoutes.settingsSiteCarePath),
                ),
                _SettingRow(
                  icon: Icons.event_available,
                  label: '一键签到',
                  value: auto.enabled ? '自动补签 ${auto.label}' : '未开启自动补签',
                  muted: !auto.enabled,
                  onTap: () => context.go(AppRoutes.settingsSignInPath),
                ),
                _SettingRow(
                  icon: Icons.shield_outlined,
                  label: 'PT 监护室',
                  value: '病危 / 站庆事件流',
                  muted: false,
                  onTap: () => context.go(AppRoutes.settingsMonitorPath),
                ),
                _SettingRow(
                  icon: Icons.grid_view_outlined,
                  label: '12 大站点',
                  value: '已配置 $configuredSlots / ${slots.length}',
                  muted: configuredSlots == 0,
                  onTap: () => context.go(AppRoutes.settingsMajorSitesPath),
                ),
                _SettingRow(
                  icon: Icons.campaign_outlined,
                  label: '推送通道',
                  value: notify.summary,
                  muted: !notify.anyEnabled,
                  onTap: () => context.go(AppRoutes.settingsNotifyPath),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '外观',
            subtitle: '默认深色主题',
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<ThemeMode>>[
                  ButtonSegment<ThemeMode>(value: ThemeMode.system, label: Text('跟随系统')),
                  ButtonSegment<ThemeMode>(value: ThemeMode.dark, label: Text('深色')),
                  ButtonSegment<ThemeMode>(value: ThemeMode.light, label: Text('浅色')),
                ],
                selected: <ThemeMode>{mode},
                onSelectionChanged: (Set<ThemeMode> selection) =>
                    ref.read(themeModeProvider.notifier).setMode(selection.first),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '网络代理',
            subtitle: '自建旁路由提供的代理服务（需求 13）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _SettingRow(
                  icon: Icons.vpn_lock_outlined,
                  label: '网络代理',
                  value: proxy.summary,
                  muted: !proxy.isUsable,
                  onTap: () => context.go(AppRoutes.settingsProxyPath),
                ),
                _SettingRow(
                  icon: Icons.lan_outlined,
                  label: '内网直连',
                  value: proxy.bypassPrivateHosts ? '已开启（内网地址不走代理）' : '未开启',
                  muted: false,
                  onTap: () => context.go(AppRoutes.settingsProxyPath),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const SectionCard(
            title: '关于',
            subtitle: '版本与配置基线',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _VersionRow(),
                _SettingRow(
                  icon: Icons.settings_suggest_outlined,
                  label: '配置版本',
                  value: 'schema v${AppConfig.configSchemaVersion}',
                  muted: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条设置项：图标 + 名称 + 当前值；传入 [onTap] 时整行可点。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.muted,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool muted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: <Widget>[
          Icon(icon, size: AppSizes.iconMd, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: muted ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onTap != null) ...<Widget>[
            const SizedBox(width: AppSpacing.xxs),
            Icon(Icons.chevron_right, size: AppSizes.iconMd, color: theme.colorScheme.onSurfaceVariant),
          ],
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
      onTap: onTap,
      child: content,
    );
  }
}

/// 应用版本行：优先读取构建信息，平台通道不可用时回退到内置版本号。
class _VersionRow extends StatelessWidget {
  const _VersionRow();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (BuildContext context, AsyncSnapshot<PackageInfo> snapshot) {
        final PackageInfo? info = snapshot.data;
        final String value = info == null
            ? 'v${AppConfig.appVersionFallback}'
            : 'v${info.version}+${info.buildNumber}';
        return _SettingRow(
          icon: Icons.info_outline,
          label: '应用版本',
          value: value,
          muted: false,
        );
      },
    );
  }
}