/// 应用级不可变常量与构建环境。
///
/// 所有超时、路径前缀、存储命名空间、schema 版本集中在此，避免散落硬编码。
/// 数值基线来自规格书 §7.5 网络链路策略 与 §9.1 API 通用规范。
library;

/// 构建环境（通过 --dart-define=APP_ENV=dev|prod 注入）。
enum AppEnvironment {
  dev,
  prod;

  static const String _raw = String.fromEnvironment('APP_ENV', defaultValue: 'prod');

  static AppEnvironment get current =>
      _raw == 'dev' ? AppEnvironment.dev : AppEnvironment.prod;

  bool get isDev => this == AppEnvironment.dev;
}

abstract final class AppConfig {
  static const String appName = 'PT Pocket';
  static const String appVersionFallback = '0.9.0';

  /// NAS 后端 API 版本与前缀（版本化 API，移动端不直连数据库/Redis）。
  static const String apiVersion = 'v1';
  static const String apiPrefix = '/api/v1';

  /// 健康探测路径：判断可用性以 API 健康状态为准，而非仅 TCP 可连接。
  static const String healthPath = '$apiPrefix/health';

  // ---------- 网络超时 ----------
  static const Duration connectTimeout = Duration(seconds: 6);
  static const Duration receiveTimeout = Duration(seconds: 20);

  /// 链路探测超时：内网 2 秒、外网 10 秒（规格书 §2.3 / §7.5）。
  static const Duration lanProbeTimeout = Duration(seconds: 2);
  static const Duration wanProbeTimeout = Duration(seconds: 10);

  /// 成功选路结果缓存 5 分钟（规格书 §2.3）。
  static const Duration endpointCacheTtl = Duration(minutes: 5);

  /// 自动模式下 LAN 优先、失败回退 WAN 的探测节奏。
  static const Duration healthProbeInterval = Duration(seconds: 30);
  static const int maxRetryAttempts = 2;
  static const Duration retryBaseDelay = Duration(milliseconds: 400);

  /// 站点连接测试超时（站点直连可达性探测）。
  static const Duration siteProbeTimeout = Duration(seconds: 8);

  /// CookieCloud / PTD 备份导入的网络超时。
  static const Duration importTimeout = Duration(seconds: 20);

  // ---------- 存储命名空间 ----------
  static const String prefsKeyPrefix = 'ptp.';
  static const String secureKeyPrefix = 'ptp_';

  /// 配置 schema 版本：升级迭代时用于触发配置迁移与继承（需求 #17）。
  /// 每次破坏性或结构性配置变更时 +1，并在 ConfigInheritanceService 注册迁移。
  /// v4：MoviePilot 实例由单一地址升级为内网 / 外网双地址。
  static const int configSchemaVersion = 5;

  /// 默认代理设置占位（旁路由代理，需求 #13：UI 在 P1 提供）。
  static const bool defaultProxyEnabled = false;
}