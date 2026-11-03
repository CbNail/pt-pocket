import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/notify_settings.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/design_tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_badge.dart';
import 'status_providers.dart';

/// 推送通道设置（需求 14：信息通过企业微信推送，或 Telegram 推送）。
///
/// 凭据（企业微信 Webhook Key、Telegram Bot Token）只保存在本机安全存储，
/// 实际发送由 NAS 后端在巡检 / 签到等事件发生时执行。
class NotifyPage extends ConsumerStatefulWidget {
  const NotifyPage({super.key});

  @override
  ConsumerState<NotifyPage> createState() => _NotifyPageState();
}

class _NotifyPageState extends ConsumerState<NotifyPage> {
  final TextEditingController _wecomWebhook = TextEditingController();
  final TextEditingController _telegramToken = TextEditingController();
  final TextEditingController _telegramChatId = TextEditingController();

  bool _wecomEnabled = false;
  bool _telegramEnabled = false;
  bool _notifyOnDanger = true;
  bool _notifyOnAnniversary = true;
  bool _notifyOnSignInFailure = true;
  bool _notifyOnTaskDone = false;
  bool _saving = false;
  NotifyChannel? _testing;
  bool _prefilled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final NotifySettings settings = ref.read(notifySettingsProvider);
    _wecomEnabled = settings.wecomEnabled;
    _telegramEnabled = settings.telegramEnabled;
    _telegramChatId.text = settings.telegramChatId;
    _notifyOnDanger = settings.notifyOnDanger;
    _notifyOnAnniversary = settings.notifyOnAnniversary;
    _notifyOnSignInFailure = settings.notifyOnSignInFailure;
    _notifyOnTaskDone = settings.notifyOnTaskDone;
  }

  @override
  void dispose() {
    _wecomWebhook.dispose();
    _telegramToken.dispose();
    _telegramChatId.dispose();
    super.dispose();
  }

  void _leave() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.settings);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final String webhook = _wecomWebhook.text.trim();
    final String token = _telegramToken.text.trim();
    final NotifySettings settings = NotifySettings(
      wecomEnabled: _wecomEnabled,
      telegramEnabled: _telegramEnabled,
      telegramChatId: _telegramChatId.text.trim(),
      notifyOnDanger: _notifyOnDanger,
      notifyOnAnniversary: _notifyOnAnniversary,
      notifyOnSignInFailure: _notifyOnSignInFailure,
      notifyOnTaskDone: _notifyOnTaskDone,
    );

    setState(() => _saving = true);
    await ref.read(notifySettingsProvider.notifier).save(
          settings,
          wecomWebhook: webhook.isEmpty ? null : webhook,
          telegramToken: token.isEmpty ? null : token,
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _wecomWebhook.clear();
      _telegramToken.clear();
    });
    _snack('推送设置已保存');
  }

  Future<void> _test(NotifyChannel channel) async {
    setState(() => _testing = channel);
    try {
      await ref.read(notifyApiProvider).sendTest(channel);
      if (!mounted) return;
      setState(() => _testing = null);
      _snack('已请求服务端向${channel.label}发送测试消息');
    } catch (error) {
      if (!mounted) return;
      setState(() => _testing = null);
      _snack('测试推送失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final NotifySettings current = ref.watch(notifySettingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('推送通道'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _leave),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: <Widget>[
          SectionCard(
            title: '推送状态',
            subtitle: current.summary,
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: <Widget>[
                StatusBadge(
                  label: current.ready ? '至少一条通道可用' : '尚不可用',
                  tone: current.ready ? StatusTone.ok : StatusTone.warning,
                  compact: true,
                ),
                StatusBadge(
                  label: '发送方：NAS 后端',
                  tone: StatusTone.info,
                  compact: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '企业微信',
            subtitle: '机器人 Webhook Key 只保存在本机安全存储',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _wecomEnabled,
                  title: const Text('启用企业微信推送'),
                  subtitle: Text(current.wecomWebhookConfigured ? 'Webhook 已保存' : 'Webhook 未保存'),
                  onChanged: (bool value) => setState(() => _wecomEnabled = value),
                ),
                TextField(
                  controller: _wecomWebhook,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Webhook Key',
                    hintText: current.wecomWebhookConfigured ? '已保存，留空表示不修改' : '未保存',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _testing == NotifyChannel.wecom
                      ? null
                      : () => _test(NotifyChannel.wecom),
                  icon: const Icon(Icons.send_outlined, size: AppSizes.iconSm),
                  label: Text(_testing == NotifyChannel.wecom ? '发送中…' : '发送测试消息'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: 'Telegram',
            subtitle: 'Bot Token 保存在本机安全存储',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _telegramEnabled,
                  title: const Text('启用 Telegram 推送'),
                  subtitle: Text(current.telegramTokenConfigured ? 'Bot Token 已保存' : 'Bot Token 未保存'),
                  onChanged: (bool value) => setState(() => _telegramEnabled = value),
                ),
                TextField(
                  controller: _telegramToken,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Bot Token',
                    hintText: current.telegramTokenConfigured ? '已保存，留空表示不修改' : '未保存',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _telegramChatId,
                  decoration: const InputDecoration(
                    labelText: 'Chat ID',
                    hintText: '个人或群组的 chat id',
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _testing == NotifyChannel.telegram
                      ? null
                      : () => _test(NotifyChannel.telegram),
                  icon: const Icon(Icons.send_outlined, size: AppSizes.iconSm),
                  label: Text(_testing == NotifyChannel.telegram ? '发送中…' : '发送测试消息'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          SectionCard(
            title: '推送范围',
            subtitle: '选择需要第一时间提醒的事件（需求 14）',
            child: Column(
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notifyOnDanger,
                  title: const Text('站点病危 / 紧急风险'),
                  onChanged: (bool value) => setState(() => _notifyOnDanger = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notifyOnAnniversary,
                  title: const Text('站庆与站点活动'),
                  onChanged: (bool value) => setState(() => _notifyOnAnniversary = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notifyOnSignInFailure,
                  title: const Text('签到失败与待补签'),
                  onChanged: (bool value) => setState(() => _notifyOnSignInFailure = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notifyOnTaskDone,
                  title: const Text('下载任务完成'),
                  onChanged: (bool value) => setState(() => _notifyOnTaskDone = value),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '说明：推送由 NAS 后端在巡检、签到与任务事件发生时发出；'
            '关闭某类事件后，该类事件只在本应用内展示。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.xl),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check, size: AppSizes.iconSm),
            label: Text(_saving ? '保存中…' : '保存推送设置'),
          ),
        ],
      ),
    );
  }
}