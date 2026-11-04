/// 本地存储键集中注册表：避免键名散落各处，迁移/清理时有唯一事实来源。
///
/// 非敏感项走 [PrefsStore]（[PrefKeys]），机密项走 [SecureStore]（[SecureKeys]）。
library;

/// 非敏感偏好键（去除 `ptp.` 命名空间前缀后的键）。
abstract final class PrefKeys {
  // 链路与服务寻址
  static const String linkMode = 'link.mode';
  static const String endpointLan = 'endpoint.lan';
  static const String endpointWan = 'endpoint.wan';
  static const String legacyServerBaseUrl = 'server.baseUrl';

  // 外观
  static const String themeMode = 'theme.mode';

  // 代理（旁路由）：整体以 JSON 保存，代理密码在 SecureStore
  static const String proxySettings = 'proxy.settings';

  // 搜索与收藏
  static const String searchPageSize = 'search.pageSize';
  static const String searchHistory = 'search.history';
  static const String favorites = 'favorites';

  // 配置继承
  static const String configSchemaVersion = 'config.schemaVersion';
  static const String lastAppVersion = 'config.lastAppVersion';

  // 站点 / 下载器 / MoviePilot 列表（索引，凭据在 SecureStore）
  static const String siteIndex = 'sites.index';
  static const String downloaderIndex = 'downloaders.index';
  static const String mpIndex = 'moviepilot.index';

  // 12 大站点槽位（需求 11：清单由用户配置）
  static const String majorSites = 'major.sites';

  // CookieCloud 导入参数（地址与 UUID 非敏感；端到端密码在 SecureStore）
  static const String cookieCloudHost = 'cookiecloud.host';
  static const String cookieCloudUuid = 'cookiecloud.uuid';

  // 推送通道设置与自动补签
  static const String notifySettings = 'notify.settings';
  static const String signInAutoEnabled = 'signin.auto.enabled';
  static const String signInAutoHour = 'signin.auto.hour';
  static const String signInAutoMinute = 'signin.auto.minute';
}

/// 机密键（去除 `ptp_` 命名空间前缀后的键）。
abstract final class SecureKeys {
  /// NAS 会话令牌（手机只持有会话令牌，站点凭据由 NAS 加密库持有）。
  static const String nasSessionToken = 'nas.sessionToken';

  /// 站点账号密码等凭据前缀：`site.cred.<siteId>`。
  static const String siteCredentialPrefix = 'site.cred.';

  /// 下载器账号密码前缀：`downloader.cred.<downloaderId>`。
  static const String downloaderCredentialPrefix = 'downloader.cred.';

  /// MoviePilot 令牌前缀：`moviepilot.cred.<mpId>`。
  static const String moviePilotCredentialPrefix = 'moviepilot.cred.';

  /// CookieCloud 端到端加密密钥（仅本机保存）。
  static const String cookieCloudKey = 'cookiecloud.key';

  /// 代理认证密码（用户名在偏好设置里，密码只在这里）。
  static const String proxyPassword = 'proxy.password';

  /// 企业微信机器人 Webhook Key（需求 14）。
  static const String notifyWecomWebhook = 'notify.wecom.webhook';

  /// Telegram Bot Token（需求 14）。
  static const String notifyTelegramToken = 'notify.telegram.token';

  static String siteCredential(String siteId) => '$siteCredentialPrefix$siteId';

  static String downloaderCredential(String downloaderId) =>
      '$downloaderCredentialPrefix$downloaderId';

  static String moviePilotCredential(String mpId) => '$moviePilotCredentialPrefix$mpId';
}