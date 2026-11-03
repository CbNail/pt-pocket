import 'package:flutter/material.dart';

import '../../core/models/major_site.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';

/// 重点站点 12 格进度矩阵（规格书 §6.4 首页布局）。
///
/// 已收集站点用品牌色与进度环表达；未配置槽位用弱文本占位。
/// 颜色不是唯一表达：每个格子同时显示槽位序号与（配置后的）站点名。
class SiteProgressMatrix extends StatelessWidget {
  const SiteProgressMatrix({super.key, required this.sites, this.onTapSlot});

  final List<MajorSiteProgress> sites;
  final void Function(MajorSiteProgress site)? onTapSlot;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 520 ? 6 : 4;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: sites.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpacing.sm,
            crossAxisSpacing: AppSpacing.sm,
            childAspectRatio: 1.02,
          ),
          itemBuilder: (BuildContext context, int index) {
            final MajorSiteProgress site = sites[index];
            return _SlotTile(
              site: site,
              supported: theme.colorScheme.primary,
              muted: theme.colorScheme.onSurfaceVariant,
              onTap: onTapSlot == null ? null : () => onTapSlot!(site),
            );
          },
        );
      },
    );
  }
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({
    required this.site,
    required this.supported,
    required this.muted,
    this.onTap,
  });

  final MajorSiteProgress site;
  final Color supported;
  final Color muted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = site.isCollected ? supported : muted;
    final double? progress = site.progress;

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: AppRadius.cardBorder,
      child: InkWell(
        borderRadius: AppRadius.cardBorder,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    '${site.slot + 1}'.padLeft(2, '0'),
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                  const Spacer(),
                  if (site.isCollected)
                    Icon(Icons.check_circle, size: AppSizes.iconSm, color: supported)
                  else
                    Icon(Icons.radio_button_unchecked, size: AppSizes.iconSm, color: muted),
                ],
              ),
              const Spacer(),
              Text(
                site.name ?? '待配置',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: site.isConfigured ? theme.colorScheme.onSurface : muted,
                  fontWeight: site.isConfigured ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress ?? (site.isCollected ? 1 : 0),
                  minHeight: 3,
                  backgroundColor: theme.colorScheme.outlineVariant,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 概览统计小卡（首页第一行）。
class OverviewStatTile extends StatelessWidget {
  const OverviewStatTile({
    super.key,
    required this.label,
    required this.value,
    this.tone = StatusTone.neutral,
    this.icon,
  });

  final String label;
  final String value;
  final StatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = tone.resolve(theme.brightness);
    return Container(
      padding: AppSpacing.cardPadding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: AppSizes.iconSm, color: color),
                const SizedBox(width: AppSpacing.xs),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(value, style: theme.textTheme.headlineSmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}