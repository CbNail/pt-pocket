import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/adapters/moviepilot_adapter_registry.dart';
import '../../core/models/moviepilot.dart';
import '../../core/models/service_health.dart';
import '../../core/network/endpoint_resolver.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../search/search_providers.dart';

/// MoviePilot 实例管理（需求 4：支持添加多个 MP，并可用自有 MP 做搜索增强）。
class MpManagePage extends ConsumerStatefulWidget {
  const MpManagePage({super.key});

  @override
  ConsumerState<MpManagePage> createState() => _MpManagePageState();
}

class _MpManagePageState extends ConsumerState<MpManagePage> {
  String? _testingId;

  /// 最近一次测试命中的通道（内网 / 外网），用于在卡片上标出当前生效链路。
  final Map<String, ActiveLink> _activeLinks = <String, ActiveLink>{};

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  /// 测试连接：走实例自己的双通道选路（内网优先、失败回退外网），并记录生效链路。
  Future<void> _test(MpInstance instance) async {
    setState(() => _testingId = instance.id);
    final EndpointResolver resolver = ref.read(mpEndpointResolverProvider(instance.id));
    resolver.invalidate();

    ResolvedEndpoint? endpoint;
    try {
      endpoint = await resolver.resolve(force: true);
    } on EndpointUnavailableException {
      endpoint = null;
    }

    await ref.read(mpListProvider.notifier).recordProbe(instance.id, endpoint != null);
    if (!mounted) return;
    setState(() {
      _testingId = null;
      if (endpoint == null) {
        _activeLinks.remove(instance.id);
      } else {
        _activeLinks[instance.id] = endpoint.link;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          endpoint == null
              ? '${instance.name}：两条通道均不可用 · ${instance.addressSummary}'
              : '${instance.name}：${endpoint.link.label}通道可用 · ${endpoint.baseUrl}',
        ),
      ),
    );
  }

  Future<void> _toggleEnhance(MpInstance instance) async {
    final bool ok = await ref.read(mpListProvider.notifier).toggleSearchEnhance(instance.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (instance.searchEnhance ? '已关闭搜索增强' : '已开启搜索增强')
              : '${instance.version.label} 适配层尚未打通，暂不能用于搜索增强',
        ),
      ),
    );
  }

  Future<void> _confirmDelete(MpInstance instance) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除 MoviePilot 实例'),
        content: Text('将删除「${instance.name}」及其在本机保存的 API 令牌，操作不可恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(mpListProvider.notifier).remove(instance.id);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AsyncValue<List<MpInstance>> listAsync = ref.watch(mpListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MoviePilot'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
      ),
      body: listAsync.when(
        loading: () => const LoadingStateView(message: '正在读取实例清单'),
        error: (Object error, StackTrace stackTrace) => ErrorStateView(
          message: '$error',
          onRetry: () => ref.invalidate(mpListProvider),
        ),
        data: (List<MpInstance> list) => list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.auto_awesome, size: 40, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(height: AppSpacing.md),
                      Text('还没有添加 MoviePilot 实例', style: theme.textTheme.titleMedium),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '可添加多个 MP；启用「搜索增强」后，聚合搜索会合并该实例的命中结果。',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      FilledButton.icon(
                        onPressed: () => context.go(AppRoutes.settingsMoviePilotAddPath),
                        icon: const Icon(Icons.add, size: AppSizes.iconSm),
                        label: const Text('添加 MoviePilot'),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
                itemCount: list.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const SizedBox(height: AppSpacing.cardGap),
                itemBuilder: (BuildContext context, int index) {
                  final MpInstance instance = list[index];
                  final MpAdapterDescriptor descriptor =
                      MoviePilotAdapterRegistry.of(instance.version);
                  return SectionCard(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(instance.name, style: theme.textTheme.titleSmall),
                                  const SizedBox(height: AppSpacing.xxs),
                                  Text(instance.addressSummary, style: theme.textTheme.bodySmall),
                                  if (_activeLinks[instance.id] != null)
                                    Text(
                                      '当前生效：${_activeLinks[instance.id]!.label}通道 · '
                                      '${instance.addressFor(_activeLinks[instance.id]!)}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                            if (_testingId == instance.id)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              PopupMenuButton<String>(
                                tooltip: '更多操作',
                                icon: const Icon(Icons.more_vert, size: AppSizes.iconMd),
                                onSelected: (String action) {
                                  switch (action) {
                                    case 'test':
                                      _test(instance);
                                    case 'edit':
                                      context.go(
                                        '${AppRoutes.settingsMoviePilotAddPath}?instanceId=${instance.id}',
                                      );
                                    case 'delete':
                                      _confirmDelete(instance);
                                  }
                                },
                                itemBuilder: (BuildContext context) =>
                                    const <PopupMenuEntry<String>>[
                                  PopupMenuItem<String>(value: 'test', child: Text('测试连接')),
                                  PopupMenuItem<String>(value: 'edit', child: Text('编辑配置')),
                                  PopupMenuDivider(),
                                  PopupMenuItem<String>(value: 'delete', child: Text('删除实例')),
                                ],
                              ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xxs,
                          children: <Widget>[
                            StatusBadge(
                              label: instance.health.label,
                              tone: instance.health == ServiceHealth.ok
                                  ? StatusTone.ok
                                  : StatusTone.neutral,
                              compact: true,
                            ),
                            StatusBadge(label: instance.version.label, tone: StatusTone.info, compact: true),
                            if (instance.hasLan && instance.hasWan)
                              const StatusBadge(label: '内网+外网', tone: StatusTone.info, compact: true),
                            if (!instance.hasAnyAddress)
                              const StatusBadge(label: '未配地址', tone: StatusTone.danger, compact: true),
                            StatusBadge(
                              label: instance.credentialConfigured ? '令牌已录入' : '待录令牌',
                              tone: instance.credentialConfigured
                                  ? StatusTone.ok
                                  : StatusTone.warning,
                              compact: true,
                            ),
                            if (!descriptor.supportsSearch)
                              const StatusBadge(
                                label: '适配层预留',
                                tone: StatusTone.neutral,
                                compact: true,
                              ),
                          ],
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: instance.searchEnhance,
                          title: const Text('用于搜索增强'),
                          subtitle: Text(descriptor.note, style: theme.textTheme.bodySmall),
                          onChanged: descriptor.supportsSearch ? (_) => _toggleEnhance(instance) : null,
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: instance.enabled,
                          title: const Text('启用该实例'),
                          onChanged: (_) => ref.read(mpListProvider.notifier).toggleEnabled(instance.id),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(AppRoutes.settingsMoviePilotAddPath),
        icon: const Icon(Icons.add),
        label: const Text('添加 MoviePilot'),
      ),
    );
  }
}

/// 显示 MoviePilot 状态色语义，保持与其他模块一致。
StatusTone mpHealthTone(ServiceHealth health) => switch (health) {
      ServiceHealth.ok => StatusTone.ok,
      ServiceHealth.warning => StatusTone.warning,
      ServiceHealth.danger => StatusTone.danger,
      ServiceHealth.unknown => StatusTone.neutral,
    };