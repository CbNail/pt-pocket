import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/status_models.dart';
import '../../core/providers.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/state_views.dart';
import '../../shared/widgets/status_badge.dart';
import '../settings/status_providers.dart';

/// 签到中心：一键签到 + 未成功站点自动补签（需求 10）。
///
/// 定时补签由 NAS 后端 worker 调度；移动端负责开关、执行时间与结果查看。
class SignInPage extends ConsumerWidget {
  const SignInPage({super.key});

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  Future<void> _pickTime(BuildContext context, WidgetRef ref, SignInAutoConfig config) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: config.hour, minute: config.minute),
    );
    if (picked == null) return;
    await ref.read(signInAutoProvider.notifier).update(
          config.copyWith(hour: picked.hour, minute: picked.minute),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final SignInAutoConfig auto = ref.watch(signInAutoProvider);
    final SignInState state = ref.watch(signInControllerProvider);
    final AsyncValue<List<SignInRecord>> recordsAsync = ref.watch(signInRecordsProvider);
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('签到中心'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _leave(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '一键签到',
            subtitle: '对已启用站点批量签到；失败站点会被记录并等待补签',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: !nasConfigured || state.running
                      ? null
                      : () => ref.read(signInControllerProvider.notifier).runAll(),
                  icon: const Icon(Icons.event_available, size: AppSizes.iconSm),
                  label: Text(state.running ? '签到中…' : '立即签到全部站点'),
                ),
                if (!nasConfigured) ...<Widget>[
                  const SizedBox(height: AppSpacing.sm),
                  Text('尚未配置 NAS 服务地址，签到由服务端执行。', style: theme.textTheme.bodySmall),
                ],
                if (state.error != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.error_outline, size: AppSizes.iconSm, color: AppColors.danger),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(state.error!, style: theme.textTheme.bodySmall)),
                    ],
                  ),
                ],
                if (state.lastResult != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: <Widget>[
                      StatusBadge(
                        label: '成功 ${state.lastResult!.successCount}',
                        tone: StatusTone.ok,
                        compact: true,
                      ),
                      StatusBadge(
                        label: '失败 ${state.lastResult!.failedCount}',
                        tone: state.lastResult!.failedCount > 0
                            ? StatusTone.danger
                            : StatusTone.neutral,
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final SignInRecord record in state.lastResult!.records)
                    _RecordRow(record: record, onRetry: () => _retry(ref, record)),
                  if (state.lastResult!.failedSites.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(
                        '未成功的站点会在设定的自动补签时间重试（可在下方开启）。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '自动补签',
            subtitle: '由 NAS 后端按设定时间执行，未成功的站点自动重试',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: auto.enabled,
                  title: const Text('开启自动补签'),
                  subtitle: Text('当前时间：${auto.label}'),
                  onChanged: (bool value) =>
                      ref.read(signInAutoProvider.notifier).update(auto.copyWith(enabled: value)),
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickTime(context, ref, auto),
                  icon: const Icon(Icons.schedule, size: AppSizes.iconSm),
                  label: const Text('设置补签时间'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '最近签到记录',
            subtitle: '来自服务端记录，用于核对失败站点',
            trailing: TextButton(
              onPressed: () => ref.invalidate(signInRecordsProvider),
              child: const Text('刷新'),
            ),
            child: recordsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: LoadingStateView(message: '读取记录'),
              ),
              error: (Object error, StackTrace stackTrace) => Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text('$error', style: theme.textTheme.bodySmall),
              ),
              data: (List<SignInRecord> records) => records.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: Text('暂无签到记录', style: theme.textTheme.bodySmall),
                    )
                  : Column(
                      children: <Widget>[
                        for (final SignInRecord record in records)
                          _RecordRow(record: record),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _retry(WidgetRef ref, SignInRecord record) =>
      ref.read(signInControllerProvider.notifier).runSite(record.siteId);
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record, this.onRetry});

  final SignInRecord record;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: <Widget>[
          StatusBadge(
            label: record.success ? '成功' : '失败',
            tone: record.success ? StatusTone.ok : StatusTone.danger,
            compact: true,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  record.siteName.isEmpty ? record.siteId : record.siteName,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                if (record.message.isNotEmpty)
                  Text(record.message, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (!record.success && onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('补签')),
        ],
      ),
    );
  }
}