/// 推送通道设置（需求 14：信息通过企业微信，或 Telegram 推送）。
///
/// 推送由 NAS 后端发出（后端持有站点会话与巡检结果）；
/// 移动端只维护通道开关与凭据，凭据本体存本机安全存储并同步给后端。
library;

/// 推送通道。
enum NotifyChannel {
  wecom('企业微信', '机器人 Webhook'),
  telegram('Telegram', 'Bot Token + Chat ID');

  const NotifyChannel(this.label, this.description);

  final String label;
  final String description;

  static NotifyChannel fromName(String? value) => values.firstWhere(
        (NotifyChannel c) => c.name == value,
        orElse: () => NotifyChannel.wecom,
      );
}

/// 推送通道设置（非机密部分）。
class NotifySettings {
  const NotifySettings({
    this.wecomEnabled = false,
    this.wecomWebhookConfigured = false,
    this.telegramEnabled = false,
    this.telegramChatId = '',
    this.telegramTokenConfigured = false,
    this.notifyOnDanger = true,
    this.notifyOnAnniversary = true,
    this.notifyOnSignInFailure = true,
    this.notifyOnTaskDone = false,
  });

  final bool wecomEnabled;

  /// 企业微信 Webhook Key 是否已录入（凭据存安全存储）。
  final bool wecomWebhookConfigured;
  final bool telegramEnabled;
  final String telegramChatId;

  /// Telegram Bot Token 是否已录入（凭据存安全存储）。
  final bool telegramTokenConfigured;

  final bool notifyOnDanger;
  final bool notifyOnAnniversary;
  final bool notifyOnSignInFailure;
  final bool notifyOnTaskDone;

  bool get anyEnabled => wecomEnabled || telegramEnabled;

  bool get anyConfigured =>
      (wecomEnabled && wecomWebhookConfigured) || (telegramEnabled && telegramTokenConfigured);

  /// 是否至少有一条可用通道。
  bool get ready =>
      (wecomEnabled && wecomWebhookConfigured) ||
      (telegramEnabled && telegramTokenConfigured && telegramChatId.trim().isNotEmpty);

  String get summary {
    if (!anyEnabled) return '未启用';
    final List<String> channels = <String>[
      if (wecomEnabled) '企业微信${wecomWebhookConfigured ? '' : '（缺 Webhook Key）'}',
      if (telegramEnabled) 'Telegram${telegramTokenConfigured ? '' : '（缺 Bot Token）'}',
    ];
    return channels.join(' + ');
  }

  NotifySettings copyWith({
    bool? wecomEnabled,
    bool? wecomWebhookConfigured,
    bool? telegramEnabled,
    String? telegramChatId,
    bool? telegramTokenConfigured,
    bool? notifyOnDanger,
    bool? notifyOnAnniversary,
    bool? notifyOnSignInFailure,
    bool? notifyOnTaskDone,
  }) =>
      NotifySettings(
        wecomEnabled: wecomEnabled ?? this.wecomEnabled,
        wecomWebhookConfigured: wecomWebhookConfigured ?? this.wecomWebhookConfigured,
        telegramEnabled: telegramEnabled ?? this.telegramEnabled,
        telegramChatId: telegramChatId ?? this.telegramChatId,
        telegramTokenConfigured: telegramTokenConfigured ?? this.telegramTokenConfigured,
        notifyOnDanger: notifyOnDanger ?? this.notifyOnDanger,
        notifyOnAnniversary: notifyOnAnniversary ?? this.notifyOnAnniversary,
        notifyOnSignInFailure: notifyOnSignInFailure ?? this.notifyOnSignInFailure,
        notifyOnTaskDone: notifyOnTaskDone ?? this.notifyOnTaskDone,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'wecomEnabled': wecomEnabled,
        'wecomWebhookConfigured': wecomWebhookConfigured,
        'telegramEnabled': telegramEnabled,
        'telegramChatId': telegramChatId,
        'telegramTokenConfigured': telegramTokenConfigured,
        'notifyOnDanger': notifyOnDanger,
        'notifyOnAnniversary': notifyOnAnniversary,
        'notifyOnSignInFailure': notifyOnSignInFailure,
        'notifyOnTaskDone': notifyOnTaskDone,
      };

  factory NotifySettings.fromJson(Map<String, dynamic> json) => NotifySettings(
        wecomEnabled: json['wecomEnabled'] as bool? ?? false,
        wecomWebhookConfigured: json['wecomWebhookConfigured'] as bool? ?? false,
        telegramEnabled: json['telegramEnabled'] as bool? ?? false,
        telegramChatId: json['telegramChatId'] as String? ?? '',
        telegramTokenConfigured: json['telegramTokenConfigured'] as bool? ?? false,
        notifyOnDanger: json['notifyOnDanger'] as bool? ?? true,
        notifyOnAnniversary: json['notifyOnAnniversary'] as bool? ?? true,
        notifyOnSignInFailure: json['notifyOnSignInFailure'] as bool? ?? true,
        notifyOnTaskDone: json['notifyOnTaskDone'] as bool? ?? false,
      );
}