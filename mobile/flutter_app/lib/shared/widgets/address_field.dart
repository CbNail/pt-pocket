import 'package:flutter/material.dart';

import '../../core/network/url_utils.dart';
import '../../core/storage/probe_result_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';

/// 探测结论的一句话描述（徽标与提示共用同一口径）。
String describeProbe(ProbeSnapshot? snapshot) {
  if (snapshot == null || !snapshot.hasResult) return '未检测';
  if (!snapshot.reachable) return '不可达';
  if (!snapshot.usable) return '地址通、服务未就绪';
  return '已连通';
}

/// 连通标记：未检测 / 检测中 / 连通 / 地址通但不可用 / 不可达。
///
/// 三档来源：不可达（网络层失败）与「地址通、但服务还没就绪」必须分开显示，
/// 否则后端未部署时会被当成地址填错。
class AddressMark extends StatelessWidget {
  const AddressMark({super.key, this.snapshot, this.probing = false, this.compact = true});

  final ProbeSnapshot? snapshot;
  final bool probing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double size = compact ? AppSizes.iconSm : AppSizes.iconMd;

    if (probing) {
      return SizedBox(
        width: size + 4,
        height: size + 4,
        child: const Center(
          child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }

    final ProbeSnapshot? value = snapshot;
    if (value == null || !value.hasResult) {
      return Icon(Icons.remove_circle_outline, size: size, color: scheme.outline);
    }
    if (!value.reachable) {
      return Icon(Icons.cancel_outlined, size: size, color: scheme.error);
    }
    if (!value.usable) {
      return Icon(Icons.error_outline, size: size, color: AppColors.warning);
    }
    return Icon(Icons.check_circle_outline, size: size, color: scheme.primary);
  }
}

/// 地址录入控件：协议点选 + 主机 + 端口 + 连通标记。
///
/// 统一约束（本轮需求）：http / https 由用户点击选择；端口有默认值且可改；
/// 主机与端口分开录入；地址填完后在右侧直接给出连通标记。
/// 直接粘贴整条 URL（含 `http://...` 或 `host:端口`）时会自动拆成三部分。
class AddressInput extends StatelessWidget {
  const AddressInput({
    super.key,
    required this.label,
    required this.scheme,
    required this.hostController,
    required this.portController,
    required this.onSchemeChanged,
    this.pathController,
    this.keyPrefix,
    this.snapshot,
    this.probing = false,
    this.onEdited,
    this.onSubmitted,
    this.hostHint = '192.168.1.10',
    this.pathHint = '反代子路径（可空，如 /ptp）',
    this.enabled = true,
  });

  final String label;

  /// 当前选中的协议：`http` / `https`。
  final String scheme;
  final TextEditingController hostController;
  final TextEditingController portController;

  /// 反代子路径（可选）。为 null 时不显示路径输入框。
  final TextEditingController? pathController;

  /// 输入框 Key 前缀；给了之后主机 / 端口 / 子路径分别是 `<前缀>.host`、`.port`、`.path`，
  /// 便于界面测试稳定定位（按顺序取 TextField 会随布局变化失效）。
  final String? keyPrefix;
  final ValueChanged<String> onSchemeChanged;

  final ProbeSnapshot? snapshot;
  final bool probing;

  /// 内容变化时回调（页面据此做延时探测）。
  final VoidCallback? onEdited;

  /// 输入完成（回车 / 失焦）时回调（页面可立即探测）。
  final VoidCallback? onSubmitted;
  final String hostHint;
  final String pathHint;
  final bool enabled;

  static const List<String> schemes = <String>['http', 'https'];

  void _selectScheme(String next) {
    if (next == scheme) return;
    // 端口兜底：空值或另一种协议的默认端口跟着切换，用户填过的非默认端口不动。
    portController.text = UrlUtils.adjustPortForScheme(
      scheme: next,
      currentPort: portController.text,
    );
    onSchemeChanged(next);
    onEdited?.call();
  }

  void _onHostChanged(String value) {
    final String text = value.trim();
    final bool pasted = text.contains('://') || RegExp(r'^[^/\s]+:\d{1,5}$').hasMatch(text);
    if (pasted) {
      final AddressParts parts = UrlUtils.split(text);
      if (!parts.isEmpty) {
        portController.text = parts.portText;
        onSchemeChanged(parts.scheme);
        hostController.text = parts.host;
        hostController.selection = TextSelection.collapsed(offset: parts.host.length);
        if (pathController != null) pathController!.text = parts.path;
        onEdited?.call();
        return;
      }
    }
    onEdited?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'http', label: Text('http')),
                ButtonSegment<String>(value: 'https', label: Text('https')),
              ],
              selected: <String>{scheme},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: WidgetStatePropertyAll<TextStyle?>(theme.textTheme.labelSmall),
              ),
              onSelectionChanged: enabled
                  ? (Set<String> values) => _selectScheme(values.first)
                  : null,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: keyPrefix == null ? null : ValueKey<String>('$keyPrefix.host'),
                controller: hostController,
                enabled: enabled,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(labelText: 'IP 或域名', hintText: hostHint),
                onChanged: _onHostChanged,
                onEditingComplete: () => onSubmitted?.call(),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Text(':'),
            ),
            SizedBox(
              width: 76,
              child: TextField(
                key: keyPrefix == null ? null : ValueKey<String>('$keyPrefix.port'),
                controller: portController,
                enabled: enabled,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(labelText: '端口'),
                onChanged: (String _) => onEdited?.call(),
                onEditingComplete: () => onSubmitted?.call(),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            AddressMark(snapshot: snapshot, probing: probing),
          ],
        ),
        if (pathController != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          TextField(
            key: keyPrefix == null ? null : ValueKey<String>('$keyPrefix.path'),
            controller: pathController,
            enabled: enabled,
            decoration: InputDecoration(labelText: '子路径', hintText: pathHint),
            onChanged: (String _) => onEdited?.call(),
            onEditingComplete: () => onSubmitted?.call(),
          ),
        ],
        if (!probing && snapshot != null && snapshot!.message.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            snapshot!.message,
            style: theme.textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// 整体连通情况的一行条目。
class AddressSummaryItem {
  const AddressSummaryItem({
    required this.name,
    required this.configured,
    this.snapshot,
    this.probing = false,
  });

  final String name;
  final bool configured;
  final ProbeSnapshot? snapshot;
  final bool probing;
}

/// 「服务地址」框底部的整体连通情况：逐条列出通道结论，并给出当前优先链路。
class AddressPairSummary extends StatelessWidget {
  const AddressPairSummary({super.key, required this.items, this.activeLabel = ''});

  final List<AddressSummaryItem> items;

  /// 当前实际优先使用的通道（如「内网」）；为空表示没有可用通道。
  final String activeLabel;

  static String describe(AddressSummaryItem item) {
    if (!item.configured) return '未配置';
    if (item.probing) return '检测中…';
    final ProbeSnapshot? value = item.snapshot;
    if (value == null || !value.hasResult) return '未检测';
    if (!value.reachable) return '不可达';
    if (!value.usable) return '地址通、服务未就绪';
    return '已连通';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final AddressSummaryItem item in items)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('${item.name}：', style: theme.textTheme.bodySmall),
                  Text(
                    describe(item),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: describe(item) == '已连通'
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  AddressMark(
                    snapshot: item.configured ? item.snapshot : null,
                    probing: item.probing,
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          activeLabel.isEmpty ? '整体情况：当前没有可用通道' : '整体情况：当前优先走$activeLabel',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}