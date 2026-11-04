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
/// 与参考实现（站点自动签到插件）对齐的三点：
/// 1. 站点分「签到站点」与「仅模拟登录站点」两类，因此这里提供
///    「签到 + 模拟登录 / 仅签到 / 仅模拟登录」三种下发方式，结果里也标注本次动作；
/// 2. 结果逐站展示成功 / 失败与原因，失败站点可直接补签；
/// 3. 提醒「程序登录 / 签到不一定被站点计为用户活跃」这一真实风险，不做「必然安全」的暗示。
///
/// 边界：抓站点、携带凭据、模拟登录与定时补签全部由 NAS 后端 worker 完成；
/// 移动端只下发方式与范围、展示结果。
class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({super.key});

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  /// 本次下发方式；默认「签到 + 模拟登录」，与后端两类站点集合一起生效。
  SignInMode _mode = SignInMode.both;

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  Future<void> _pickTime(SignInAutoConfig config) async {
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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SignInAutoConfig auto = ref.watch(signInAutoProvider);
    final SignInState state = ref.watch(signInControllerProvider);
    final AsyncValue<List<SignInRecord>> recordsAsync = ref.watch(signInRecordsProvider);
    final bool nasConfigured = ref.watch(endpointProfileProvider).isConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text('签到中心'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '一键签到',
            subtitle: '对已启用站点批量下发；失败站点会被记录并等待补签',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SegmentedButton<SignInMode>(
                  segments: <ButtonSegment<SignInMode>>[
                    for (final SignInMode mode in SignInMode.values)
                      ButtonSegment<SignInMode>(value: mode, label: Text(mode.label)),
                  ],
                  selected: <SignInMode>{_mode},
                  onSelectionChanged: (Set<SignInMode> value) =>
                      setState(() => _mode = value.first),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _mode == SignInMode.login
                      ? '只对「仅模拟登录」的站点下发：有些站点不定义签到，只能靠模拟登录维持活跃。'
                      : (_mode == SignInMode.signin
                          ? '只对「签到站点」下发，跳过只做模拟登录的站点。'
                          : '两类站点都会处理：能签到的签到，只能模拟登录的做模拟登录。'),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed: !nasConfigured || state.running
                      ? null
                      : () => ref.read(signInControllerProvider.notifier).runAll(mode: _mode),
                  icon: const Icon(Icons.event_available, size: AppSizes.iconSm),
                  label: Text(state.running ? '签到中…' : '立即执行（${_mode.label}）'),
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.info_outline, size: AppSizes.iconSm, color: AppColors.warning),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '注意：并非所有站点都把程序登录 / 签到计为用户活跃（例如馒头），'
                        '因此提示成功仍可能存在掉号风险，请以站点公告为准。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
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
                  if (state.lastResult!.notice.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.xs),
                    Text(state.lastResult!.notice, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  for (final SignInRecord record in state.lastResult!.records)
                    _RecordRow(
                      record: record,
                      onRetry: () => ref
                          .read(signInControllerProvider.notifier)
                          .runSite(record.siteId, mode: _mode),
                    ),
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
                  onPressed: () => _pickTime(auto),
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
          const SizedBox(width: AppSpacing.xs),
          // 本次做的是签到还是模拟登录：两类站点的结果不能混着看。
          StatusBadge(
            label: record.action.label,
            tone: StatusTone.info,
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
                  Text(record.message,
                      style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                if (record.signedAt != null)
                  Text(
                    '${record.signedAt!.year}-${record.signedAt!.month.toString().padLeft(2, '0')}-'
                    '${record.signedAt!.day.toString().padLeft(2, '0')} '
                    '${record.signedAt!.hour.toString().padLeft(2, '0')}:'
                    '${record.signedAt!.minute.toString().padLeft(2, '0')}',
                    style: theme.textTheme.bodySmall,
                  ),
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