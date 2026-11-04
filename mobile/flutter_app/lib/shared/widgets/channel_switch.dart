import 'package:flutter/material.dart';

import '../../core/storage/probe_result_store.dart';
import '../../core/theme/design_tokens.dart';
import 'address_field.dart';

/// 一条通道（内网 / 外网）的展示信息。
class ChannelPane {
  const ChannelPane({
    required this.label,
    required this.configured,
    required this.child,
    this.snapshot,
    this.probing = false,
  });

  final String label;
  final bool configured;

  /// 该通道的录入控件（通常是 [AddressInput]）。
  final Widget child;
  final ProbeSnapshot? snapshot;
  final bool probing;
}

/// 内外网双通道录入：左侧切换、右侧只显示当前通道。
///
/// 两栏并排会把地址区撑到两屏高，且两条通道的录入控件长得一模一样、
/// 容易看错行；改成切换后一次只处理一条，左侧标签上保留另一条的连通标记，
/// 底部的整体连通情况（[AddressPairSummary]）始终可见，两边都不丢信息。
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
    final int safeIndex = index < 0 || index >= panes.length ? 0 : index;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < panes.length; i++) ...<Widget>[
              _ChannelTab(
                pane: panes[i],
                selected: i == safeIndex,
                onTap: () => onIndexChanged(i),
              ),
              if (i != panes.length - 1) const SizedBox(height: AppSpacing.xs),
            ],
          ],
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: panes[safeIndex].child),
      ],
    );
  }
}

class _ChannelTab extends StatelessWidget {
  const _ChannelTab({required this.pane, required this.selected, required this.onTap});

  final ChannelPane pane;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color background =
        selected ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHigh;
    final Color foreground =
        selected ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant;

    return Semantics(
      selected: selected,
      button: true,
      label: '${pane.label}地址',
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.cardBorder,
        child: Container(
          width: 56,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.xs),
          decoration: BoxDecoration(
            color: background,
            borderRadius: AppRadius.cardBorder,
            border: Border.all(
              color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                pane.label,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              // 未选中的通道也要能看出通不通，否则切过去才知道。
              AddressMark(snapshot: pane.snapshot, probing: pane.probing),
              if (!pane.configured) ...<Widget>[
                const SizedBox(height: 2),
                Text('未填', style: theme.textTheme.labelSmall?.copyWith(color: foreground)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}