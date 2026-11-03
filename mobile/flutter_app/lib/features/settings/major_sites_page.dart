import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/pt_site.dart';
import '../../core/models/status_models.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../sites/site_providers.dart';
import 'status_providers.dart';

/// 12 大站点收集进度配置（需求 11）。
///
/// 清单由用户自行配置（应用不内置臆造的站点名单）：
/// 每个槽位可填显示名并关联已添加的站点，配置完成后主页按槽位展示收集进度。
class MajorSitesPage extends ConsumerWidget {
  const MajorSitesPage({super.key});

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  Future<void> _editSlot(
    BuildContext context,
    WidgetRef ref,
    MajorSiteSlot slot,
    List<PtSite> sites,
  ) async {
    final TextEditingController nameController = TextEditingController(text: slot.name);
    String siteId = slot.siteId;

    final MajorSiteSlot? result = await showDialog<MajorSiteSlot>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext dialogContext, StateSetter setLocalState) => AlertDialog(
          title: Text('编辑槽位 ${slot.slot}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '显示名称',
                  hintText: '例如：站点简称（留空则显示「槽位 n」）',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: siteId,
                decoration: const InputDecoration(labelText: '关联站点'),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(value: '', child: Text('未关联')),
                  for (final PtSite site in sites)
                    DropdownMenuItem<String>(value: site.id, child: Text(site.name)),
                ],
                onChanged: (String? value) => setLocalState(() => siteId = value ?? ''),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                slot.copyWith(name: nameController.text.trim(), siteId: siteId),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    if (result == null) return;
    await ref.read(majorSiteSlotsProvider.notifier).upsert(result);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final List<MajorSiteSlot> slots =
        ref.watch(majorSiteSlotsProvider).valueOrNull ?? MajorSiteSlot.defaults();
    final List<PtSite> sites = ref.watch(siteListProvider).valueOrNull ?? const <PtSite>[];
    final int configured = slots.where((MajorSiteSlot s) => s.isConfigured).length;
    final double progress = slots.isEmpty ? 0 : configured / slots.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('12 大站点'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _leave(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '收集进度',
            subtitle: '$configured / ${slots.length} 已配置',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  child: LinearProgressIndicator(value: progress.clamp(0, 1), minHeight: 6),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '已配置的槽位会出现在主页的收集进度矩阵中。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (sites.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: PartialResultBanner(
                message: '还没有添加任何站点；可先在站点模块添加，再回到这里关联槽位。',
              ),
            ),
          for (final MajorSiteSlot slot in slots)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SectionCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                onTap: () => _editSlot(context, ref, slot, sites),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.chip)),
                      ),
                      child: Text('${slot.slot}', style: theme.textTheme.labelMedium),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            slot.name.isEmpty ? '槽位 ${slot.slot}' : slot.name,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: AppSpacing.xxs),
                          Text(
                            _siteLabel(sites, slot.siteId),
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.edit_outlined,
                      size: AppSizes.iconMd,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _siteLabel(List<PtSite> sites, String siteId) {
    if (siteId.isEmpty) return '未关联站点';
    for (final PtSite site in sites) {
      if (site.id == siteId) return '已关联：${site.name}';
    }
    return '已关联的站点已删除';
  }
}