/// 站点模型与枚举。
///
/// 模型只承载非机密的站点配置；凭据（Cookie / Passkey / API Key / 账号密码）
/// 一律由 `SecureStore` 持有，模型里仅记录「是否已配置」的布尔标记。
library;

/// 站点适配框架：决定使用哪个适配器解析站点页面与接口。
///
/// 内置的是**适配定义**（框架级），不含任何具体站点名单——
/// 站点由用户自行添加，避免内置臆造的站点信息。
enum SiteFramework {
  nexusphp('NexusPHP', '通用 NexusPHP 结构适配定义'),
  unit3d('Unit3D', '基于 Laravel 的 Unit3D 结构适配定义'),
  gazelle('Gazelle', 'Gazelle 结构适配定义'),
  custom('自定义', '按站点自定义规则的适配定义');

  const SiteFramework(this.label, this.description);

  final String label;
  final String description;

  static SiteFramework fromName(String? value) => values.firstWhere(
        (SiteFramework f) => f.name == value,
        orElse: () => SiteFramework.nexusphp,
      );
}

/// 站点认证方式。
enum SiteAuthType {
  cookie('Cookie', '浏览器登录态 Cookie，可从 CookieCloud 一键导入'),
  passkey('Passkey', '站点发放的 Passkey 链接'),
  apiKey('API Key', '站点 API 密钥'),
  account('账号密码', '站点账号与密码，用于内置 WebView 手动登录');

  const SiteAuthType(this.label, this.description);

  final String label;
  final String description;

  static SiteAuthType fromName(String? value) => values.firstWhere(
        (SiteAuthType t) => t.name == value,
        orElse: () => SiteAuthType.cookie,
      );
}

/// 站点连接状态（本地记录；展示时必须配文字，颜色不是唯一表达）。
enum SiteHealth {
  unknown('未测试'),
  ok('正常'),
  warning('需关注'),
  danger('异常');

  const SiteHealth(this.label);

  final String label;

  static SiteHealth fromName(String? value) => values.firstWhere(
        (SiteHealth h) => h.name == value,
        orElse: () => SiteHealth.unknown,
      );
}

/// 站点配置（非机密）。
class PtSite {
  const PtSite({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.framework = SiteFramework.nexusphp,
    this.authType = SiteAuthType.cookie,
    this.enabled = true,
    this.favorite = false,
    this.credentialConfigured = false,
    this.health = SiteHealth.unknown,
    this.lastTestedAt,
    this.createdAt,
    this.updatedAt,
    this.note,
  });

  final String id;
  final String name;
  final String baseUrl;
  final SiteFramework framework;
  final SiteAuthType authType;

  /// 是否参与聚合搜索与签到巡检。
  final bool enabled;
  final bool favorite;

  /// 凭据是否已录入（仅标记，凭据本体在 SecureStore）。
  final bool credentialConfigured;
  final SiteHealth health;
  final DateTime? lastTestedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? note;

  String get host => Uri.tryParse(baseUrl)?.host ?? baseUrl;

  PtSite copyWith({
    String? id,
    String? name,
    String? baseUrl,
    SiteFramework? framework,
    SiteAuthType? authType,
    bool? enabled,
    bool? favorite,
    bool? credentialConfigured,
    SiteHealth? health,
    DateTime? lastTestedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? note,
  }) =>
      PtSite(
        id: id ?? this.id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        framework: framework ?? this.framework,
        authType: authType ?? this.authType,
        enabled: enabled ?? this.enabled,
        favorite: favorite ?? this.favorite,
        credentialConfigured: credentialConfigured ?? this.credentialConfigured,
        health: health ?? this.health,
        lastTestedAt: lastTestedAt ?? this.lastTestedAt,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'framework': framework.name,
        'authType': authType.name,
        'enabled': enabled,
        'favorite': favorite,
        'credentialConfigured': credentialConfigured,
        'health': health.name,
        'lastTestedAt': lastTestedAt?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
        'note': note,
      };

  factory PtSite.fromJson(Map<String, dynamic> json) => PtSite(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        baseUrl: json['baseUrl'] as String? ?? '',
        framework: SiteFramework.fromName(json['framework'] as String?),
        authType: SiteAuthType.fromName(json['authType'] as String?),
        enabled: json['enabled'] as bool? ?? true,
        favorite: json['favorite'] as bool? ?? false,
        credentialConfigured: json['credentialConfigured'] as bool? ?? false,
        health: SiteHealth.fromName(json['health'] as String?),
        lastTestedAt: parseStoredDate(json['lastTestedAt']),
        createdAt: parseStoredDate(json['createdAt']),
        updatedAt: parseStoredDate(json['updatedAt']),
        note: json['note'] as String?,
      );
}

/// 宽松解析本地存储中的时间字符串。
DateTime? parseStoredDate(Object? value) => value is String ? DateTime.tryParse(value) : null;