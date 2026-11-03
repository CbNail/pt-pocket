// 推送通道设置测试：JSON 往返、可用性判断与摘要文案。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/notify_settings.dart';

void main() {
  test('未启用时不可用', () {
    const NotifySettings settings = NotifySettings();
    expect(settings.anyEnabled, isFalse);
    expect(settings.ready, isFalse);
    expect(settings.summary, '未启用');
  });

  test('启用但缺少凭据不算可用', () {
    const NotifySettings wecom = NotifySettings(wecomEnabled: true);
    expect(wecom.anyEnabled, isTrue);
    expect(wecom.ready, isFalse);
    expect(wecom.summary, contains('缺 Webhook Key'));

    const NotifySettings telegram =
        NotifySettings(telegramEnabled: true, telegramTokenConfigured: true);
    expect(telegram.ready, isFalse, reason: '缺少 Chat ID');

    const NotifySettings telegramReady = NotifySettings(
      telegramEnabled: true,
      telegramTokenConfigured: true,
      telegramChatId: '12345',
    );
    expect(telegramReady.ready, isTrue);
  });

  test('企业微信凭据齐全即为可用', () {
    const NotifySettings settings =
        NotifySettings(wecomEnabled: true, wecomWebhookConfigured: true);
    expect(settings.anyConfigured, isTrue);
    expect(settings.ready, isTrue);
    expect(settings.summary, contains('企业微信'));
  });

  test('JSON 往返保留全部字段', () {
    const NotifySettings source = NotifySettings(
      wecomEnabled: true,
      wecomWebhookConfigured: true,
      telegramEnabled: true,
      telegramChatId: 'chat-1',
      telegramTokenConfigured: true,
      notifyOnDanger: false,
      notifyOnAnniversary: true,
      notifyOnSignInFailure: false,
      notifyOnTaskDone: true,
    );

    final NotifySettings restored = NotifySettings.fromJson(source.toJson());

    expect(restored.wecomEnabled, isTrue);
    expect(restored.wecomWebhookConfigured, isTrue);
    expect(restored.telegramEnabled, isTrue);
    expect(restored.telegramChatId, 'chat-1');
    expect(restored.telegramTokenConfigured, isTrue);
    expect(restored.notifyOnDanger, isFalse);
    expect(restored.notifyOnAnniversary, isTrue);
    expect(restored.notifyOnSignInFailure, isFalse);
    expect(restored.notifyOnTaskDone, isTrue);
  });

  test('copyWith 可单独切换通道开关', () {
    const NotifySettings settings = NotifySettings();
    expect(settings.copyWith(wecomEnabled: true).wecomEnabled, isTrue);
    expect(settings.copyWith(wecomEnabled: true).telegramEnabled, isFalse);
  });

  test('通道枚举名称可解析且回退到企业微信', () {
    expect(NotifyChannel.fromName('telegram'), NotifyChannel.telegram);
    expect(NotifyChannel.fromName(null), NotifyChannel.wecom);
  });
}