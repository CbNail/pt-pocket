import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/endpoint_resolver.dart';
import '../../core/providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';

/// NAS 链路徽标：显示当前实际选路（内网 / 外网 / 未连接）与链路模式。
///
/// 对应需求 #16：任何访问自建服务的功能都要支持内外网两种访问方式并自动切换。
class LinkBadge extends ConsumerWidget {
  const LinkBadge({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EndpointProfile profile = ref.watch(endpointProfileProvider);
    final ThemeData theme = Theme.of(context);

    final (StatusTone tone, String label, IconData icon) = switch (profile) {
      EndpointProfile(isConfigured: false) => (
          StatusTone.neutral,
          '未配置',
          Icons.link_off,
        ),
      EndpointProfile(mode: LinkMode.lan) => (StatusTone.info, '内网', Icons.lan_outlined),
      EndpointProfile(mode: LinkMode.wan) => (StatusTone.info, '外网', Icons.public),
      _ => (StatusTone.info, '自动', Icons.swap_horiz),
    };

    final Color color = tone.resolve(theme.brightness);

    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.badge)),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.badge)),
          border: Border.all(color: color.withValues(alpha: 0.36)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: AppSizes.iconSm, color: color),
            const SizedBox(width: AppSpacing.xs),
            Text(
              'NAS · $label',
              style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}