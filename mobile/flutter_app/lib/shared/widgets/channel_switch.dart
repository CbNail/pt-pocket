import 'package:flutter/material.dart';

import '../../core/storage/probe_result_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import 'address_field.dart';

/// 通道配色（内网＝品牌绿、外网＝信息蓝），按明暗主题自动取色。
enum ChannelAccent {
  lan,
  wan;

  Color resolve(Brightness brightness) => switch (this) {
        ChannelAccent.lan =>
          brightness == Brightness.dark ? AppColors.brand : AppColors.lightBrand,
        ChannelAccent.wan =>
          brightness == Brightness.dark ? AppColors.info : AppColors.lightInfo,
      };
}

/// 一条通道（内网 / 外网）的展示信息。
class ChannelPane {
  const ChannelPane({
    required this.label,
    required this.configured,
    required this.child,
    this.snapshot,
    this.probing = false,
    this.accent = ChannelAccent.lan,
  });

  final String label;
  final bool configured;

  /// 该通道的录入控件（通常是 [AddressInput]）。
  final Widget child;
  final ProbeSnapshot? snapshot;
  final bool probing;

  /// 该通道的配色（内网 / 外网）；缺省按明暗主题取内网色。
  final ChannelAccent accent;
}

/// 内外网双通道录入：**一个按钮**切换，按钮底色随当前通道变化。
///
/// 交互（本轮改造）：
/// - 内网 / 外网的「两个竖排按钮」合并成一个按钮，点一下在两条通道之间切换；
/// - 按钮底色与文字色跟着当前通道变化（内网＝绿色系、外网＝蓝色系），
///   一眼能看出现在填的是哪条；
/// - 按钮里依然保留另一条通道的连通标记（否则要切过去才知道通不通），
///   底部 [AddressPairSummary] 的整体情况也始终可见。
class ChannelSwitch extends StatelessWidget {
  const ChannelSwitch({
    super.key,
    required this.panes,
    required this.index,
    required this.onIndexChanged,
  });

  final List<ChannelPane> panes;
  final int index;
  final ValueChanged<int> onIndexChanged;

  @override
  Widget build(BuildContext context) {
    if (panes.isEmpty) return const SizedBox.shrink();
    final int safeIndex = index < 0 || index >= panes.length ? 0 : index;
    final int otherIndex = panes.length < 2 ? safeIndex : (safeIndex + 1) % panes.length;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _ChannelToggle(
          active: panes[safeIndex],
          other: panes[otherIndex],
          switchable: panes.length > 1,
          onTap: () => onIndexChanged(otherIndex),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: panes[safeIndex].child),
      ],
    );
  }
}

/// 合并后的单按钮：当前通道 + 另一通道的连通标记 + 切换提示。
class _ChannelToggle extends StatelessWidget {
  const _ChannelToggle({
    required this.active,
    required this.other,
    required this.switchable,
    required this.onTap,
  });

  final ChannelPane active;
  final ChannelPane other;
  final bool switchable;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = active.accent.resolve(theme.brightness);

    return Semantics(
      button: true,
      selected: true,
      label: switchable ? '当前 ${active.label}，点击切换到 ${other.label}' : '${active.label}地址',
      child: InkWell(
        onTap: switchable ? onTap : null,
        borderRadius: AppRadius.cardBorder,
        child: AnimatedContainer(
          duration: AppDurations.normal,
          curve: Curves.easeOut,
          width: 84,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.xs),
          decoration: BoxDecoration(
            // 底色随当前通道变化：这是「一个按钮区分内网 / 外网」的主要表达。
            color: accent.withValues(alpha: 0.16),
            borderRadius: AppRadius.cardBorder,
            border: Border.all(color: accent.withValues(alpha: 0.55)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    active.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (switchable) ...<Widget>[
                    const SizedBox(width: 2),
                    Icon(Icons.swap_horiz, size: 14, color: accent),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.xxs),
              AddressMark(snapshot: active.snapshot, probing: active.probing),
              if (!active.configured) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  '未填',
                  style: theme.textTheme.labelSmall?.copyWith(color: accent),
                ),
              ],
              if (switchable) ...<Widget>[
                const SizedBox(height: AppSpacing.xs),
                Divider(height: 1, color: accent.withValues(alpha: 0.3)),
                const SizedBox(height: AppSpacing.xs),
                // 另一条通道的通断仍然可见，避免「切过去才知道」。
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      other.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    AddressMark(snapshot: other.snapshot, probing: other.probing),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}