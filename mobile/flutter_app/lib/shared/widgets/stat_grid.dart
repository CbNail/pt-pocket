import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 单个统计项：标题在上、数值在下，同一行内等宽对齐。
class StatItem {
  const StatItem({required this.label, required this.value, this.tone, this.collected = true});

  final String label;
  final String value;

  /// 数值色（例如上传用绿、下载用粉）；为空时用主题正文色。
  final Color? tone;

  /// 是否已采集；false 时数值以弱化色显示（界面统一用「未采集」这样的文案）。
  final bool collected;
}

/// 等宽统计网格：固定 [columns] 列，每行都铺满。
///
/// 条目数不是列数整数倍时，行尾用**同宽空位**补齐——这样换行后的最后一行
/// 在宽度上依然是满行，不会出现半行留空、左右不对齐的问题。
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.items, this.columns = 3});

  final List<StatItem> items;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (int start = 0; start < items.length; start += columns) {
      final List<Widget> cells = <Widget>[];
      for (int i = 0; i < columns; i++) {
        final int index = start + i;
        cells.add(Expanded(
          child: index < items.length
              ? _StatCell(item: items[index])
              : const SizedBox.shrink(),
        ));
      }
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: cells,
        ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.item});

  final StatItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color? valueColor = item.tone ??
        (item.collected ? null : theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          item.label,
          style: theme.textTheme.labelSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          item.value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: valueColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}