import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 等宽胶囊网格：固定列数，每行都铺满。
///
/// 条目数不是列数整数倍时，行尾用**同宽空位**补齐——这样换行后的最后一行
/// 在宽度上仍然是满行，不会出现「第二行只占一半、左右不对齐」的情况。
class EqualChipGrid extends StatelessWidget {
  const EqualChipGrid({
    super.key,
    required this.children,
    this.columns = 3,
    this.spacing = AppSpacing.xs,
  });

  final List<Widget> children;
  final int columns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double cell = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        final int remainder = children.length % columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final Widget child in children) SizedBox(width: cell, child: child),
            // 补齐最后一行：空位只占横向空间（不撑高），保证行宽铺满。
            for (int i = remainder; i != 0 && i < columns; i++) SizedBox(width: cell),
          ],
        );
      },
    );
  }
}