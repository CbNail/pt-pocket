import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 左滑露出的单个操作按钮。
class SwipeActionButton {
  const SwipeActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.background,
    this.foreground,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// 背景色；为空时用主题色。
  final Color? background;
  final Color? foreground;

  /// 为 false 时按钮仍显示但不可点（例如“默认”已经是默认项）。
  final bool enabled;
}

/// 列表项左滑露出操作按钮。
///
/// 行为约定（与需求 3 对齐）：
/// - 向左滑动超过四分之一展开宽度即展开，展开宽度 = 按钮数 × [actionWidth]；
/// - 已展开的行再次点击不会进入详情（由 [onTapWhileOpen] 决定，默认只收起）；
/// - 同一列表同时只允许一行展开：外部把当前展开行的 key 传进 [openKey]，
///   其它行收到不同 key 时自动收起。
class SwipeActionRow extends StatefulWidget {
  const SwipeActionRow({
    super.key,
    required this.itemKey,
    required this.actions,
    required this.child,
    this.openKey,
    this.onOpen,
    this.actionWidth = 76,
  });

  /// 本行标识，用于与 [openKey] 比对。
  final String itemKey;
  final List<SwipeActionButton> actions;
  final Widget child;

  /// 当前展开行的 key；与本行不同时本行强制收起。
  final String? openKey;

  /// 展开状态变化回调；展开时传本行 key，收起时传 null。
  final ValueChanged<String?>? onOpen;

  final double actionWidth;

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow> {
  double _offset = 0;
  bool _dragging = false;

  double get _totalWidth => widget.actions.length * widget.actionWidth;

  bool get _isOpen => _offset != 0;

  @override
  void didUpdateWidget(covariant SwipeActionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 别的行展开了 → 本行收起。
    if (_offset != 0 && widget.openKey != widget.itemKey) {
      setState(() => _offset = 0);
    }
  }

  void _close() {
    if (!_isOpen) return;
    setState(() => _offset = 0);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // 背景层：操作按钮靠右排列，被上层卡片遮住，只有滑开才露出来。
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: _totalWidth,
              child: ClipRRect(
                borderRadius: AppRadius.cardBorder,
                child: Row(
                  children: <Widget>[
                    for (final SwipeActionButton action in widget.actions)
                      Expanded(
                        child: _ActionButtonView(action: action, onDone: _close),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: _offset),
          duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          builder: (BuildContext context, double value, Widget? child) =>
              Transform.translate(offset: Offset(value, 0), child: child),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (DragStartDetails _) => setState(() => _dragging = true),
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              setState(() {
                _dragging = true;
                _offset = (_offset + details.delta.dx).clamp(-_totalWidth, 0.0);
              });
            },
            onHorizontalDragEnd: (DragEndDetails _) {
              final bool open = _offset < -_totalWidth / 4;
              setState(() {
                _dragging = false;
                _offset = open ? -_totalWidth : 0;
              });
              widget.onOpen?.call(open ? widget.itemKey : null);
            },
            onHorizontalDragCancel: () {
              setState(() {
                _dragging = false;
                _offset = _isOpen ? -_totalWidth : 0;
              });
            },
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

class _ActionButtonView extends StatelessWidget {
  const _ActionButtonView({required this.action, required this.onDone});

  final SwipeActionButton action;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color background = action.enabled
        ? (action.background ?? theme.colorScheme.secondaryContainer)
        : theme.colorScheme.surfaceContainerHighest;
    final Color foreground = action.enabled
        ? (action.foreground ?? theme.colorScheme.onSecondaryContainer)
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: background,
      child: InkWell(
        onTap: action.enabled
            ? () {
                onDone();
                action.onTap();
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(action.icon, size: AppSizes.iconSm, color: foreground),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                action.label,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}