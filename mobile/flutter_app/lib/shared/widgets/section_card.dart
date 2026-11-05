import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 统一卡片容器：卡片圆角 16 dp、低对比边界、可选标题栏。
///
/// 所有列表/分区容器都应使用本组件，避免各自硬编码圆角与边框（规格书 §6.3）。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    this.child,
    this.padding,
    this.onTap,
    this.onLongPress,
  });

  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  /// 长按手势（例如「长按进入多选」）；与 [onTap] 独立，两者可同时给。
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget body = Padding(
      padding: padding ?? AppSpacing.cardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (title != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title!, style: theme.textTheme.titleMedium),
                      if (subtitle != null) ...<Widget>[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(subtitle!, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          if (title != null && child != null) const SizedBox(height: AppSpacing.md),
          ?child,
        ],
      ),
    );

    final Widget card = DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: AppRadius.cardBorder,
        border: Border.all(color: theme.colorScheme.outline),
      ),
      // 卡片背景是不透明底色，若直接把 ListTile / SwitchListTile 放进来，
      // 它们的背景与点击水波纹会画在更外层的 Material 上、被这层底色盖住，
      // 调试模式下会直接抛断言（“ListTile background color or ink splashes may be invisible”）。
      // 这里垫一层透明 Material，让卡片内的列表项把水波纹画在这层上。
      child: Material(type: MaterialType.transparency, child: body),
    );

    if (onTap == null && onLongPress == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: AppRadius.cardBorder,
        onTap: onTap,
        onLongPress: onLongPress,
        child: card,
      ),
    );
  }
}