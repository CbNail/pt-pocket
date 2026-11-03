import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';

/// 状态徽标：小面积色块 + 文字 + 可选图标。
///
/// 颜色不能成为唯一状态表达方式（规格书 §6.2），因此徽标始终包含文字（可带图标）。
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.tone = StatusTone.neutral,
    this.icon,
    this.compact = false,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = tone.resolve(theme.brightness);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppSpacing.sm : AppSpacing.md,
        vertical: compact ? 3 : AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.badge)),
        border: Border.all(color: color.withValues(alpha: 0.36)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: AppSizes.iconSm, color: color),
            const SizedBox(width: AppSpacing.xs),
          ] else ...<Widget>[
            Container(
              width: AppSizes.badgeDot,
              height: AppSizes.badgeDot,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label,
            style: (compact ? theme.textTheme.labelSmall : theme.textTheme.labelMedium)
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 状态点：仅用于紧凑列表左侧的细色条 + 文字兜底由外层提供。
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, this.tone = StatusTone.neutral, this.width = AppSizes.badgeBarWidth});

  final StatusTone tone;
  final double width;

  @override
  Widget build(BuildContext context) {
    final Color color = tone.resolve(Theme.of(context).brightness);
    return Container(
      width: width,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(width)),
    );
  }
}