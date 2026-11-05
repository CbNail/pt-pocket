import '../models/pt_site.dart';

/// 单个站点适配定义（本产品自研适配器的能力声明，不是对第三方站点的承诺）。
///
/// 服务端适配器按 [adapterId] 注册；移动端只用它做表单联动与能力提示。
class SiteAdapterDescriptor {
  const SiteAdapterDescriptor({
    required this.framework,
    required this.adapterId,
    required this.supportedAuthTypes,
    required this.recommendedAuthType,
    this.supportsSearch = true,
    this.supportsSignIn = true,
    this.supportsUserProfile = true,
    this.note = '',
  });

  final SiteFramework framework;

  /// 服务端适配器注册名。
  final String adapterId;

  final Set<SiteAuthType> supportedAuthTypes;

  /// 该结构的**推荐认证方式**（表单默认项；用户可在添加 / 编辑页自行改）。
  final SiteAuthType recommendedAuthType;
  final bool supportsSearch;
  final bool supportsSignIn;
  final bool supportsUserProfile;
  final String note;

  /// 为什么推荐这种认证方式（表单里展示的一句话）。
  String get authRecommendationNote => switch (recommendedAuthType) {
        SiteAuthType.cookie =>
          '${framework.label} 结构以页面解析为主，推荐用 Cookie 维护登录态；'
              '若站点允许，也可改用 Passkey / API Key。',
        SiteAuthType.apiKey =>
          '${framework.label} 提供官方 API，推荐用存取令牌（API Key），比 Cookie 更稳定、也更不容易触发风控。',
        SiteAuthType.passkey =>
          '${framework.label} 可用 Passkey 免登录取下载链接，推荐优先使用 Passkey。',
        SiteAuthType.account =>
          '该结构没有稳定的接口凭据，推荐用账号密码配合内置浏览器登录。',
      };
}

/// 内置适配定义注册表（框架级，不含具体站点）。
abstract final class SiteAdapterRegistry {
  static const List<SiteAdapterDescriptor> descriptors = <SiteAdapterDescriptor>[
    SiteAdapterDescriptor(
      framework: SiteFramework.nexusphp,
      adapterId: 'nexusphp',
      supportedAuthTypes: <SiteAuthType>{
        SiteAuthType.cookie,
        SiteAuthType.apiKey,
        SiteAuthType.passkey,
      },
      recommendedAuthType: SiteAuthType.cookie,
      note: 'NexusPHP 结构适配定义：Cookie 维护登录态，站点 API 用于搜索与个人数据。',
    ),
    SiteAdapterDescriptor(
      framework: SiteFramework.unit3d,
      adapterId: 'unit3d',
      supportedAuthTypes: <SiteAuthType>{SiteAuthType.cookie, SiteAuthType.apiKey},
      recommendedAuthType: SiteAuthType.apiKey,
      note: 'Unit3D 结构适配定义：搜索与个人数据依赖站点 API 密钥。',
    ),
    SiteAdapterDescriptor(
      framework: SiteFramework.gazelle,
      adapterId: 'gazelle',
      supportedAuthTypes: <SiteAuthType>{SiteAuthType.cookie, SiteAuthType.apiKey},
      recommendedAuthType: SiteAuthType.apiKey,
      note: 'Gazelle 结构适配定义：官方 API 用密钥认证，页面解析需要登录态。',
    ),
    SiteAdapterDescriptor(
      framework: SiteFramework.btitracker,
      adapterId: 'btitracker',
      supportedAuthTypes: <SiteAuthType>{
        SiteAuthType.cookie,
        SiteAuthType.passkey,
        SiteAuthType.apiKey,
      },
      recommendedAuthType: SiteAuthType.cookie,
      note: 'BtiTracker / TBDev 系结构适配定义：以页面解析为主，Cookie 维护登录态。',
    ),
    SiteAdapterDescriptor(
      framework: SiteFramework.custom,
      adapterId: 'custom',
      supportedAuthTypes: <SiteAuthType>{
        SiteAuthType.cookie,
        SiteAuthType.apiKey,
        SiteAuthType.passkey,
        SiteAuthType.account,
      },
      supportsSearch: false,
      supportsSignIn: false,
      supportsUserProfile: false,
      recommendedAuthType: SiteAuthType.cookie,
      note: '自定义适配定义：仅维护登录态与可达性监测，搜索与个人数据需补齐站点规则。',
    ),
  ];

  static SiteAdapterDescriptor of(SiteFramework framework) => descriptors.firstWhere(
        (SiteAdapterDescriptor d) => d.framework == framework,
        orElse: () => descriptors.last,
      );

  static bool supportsAuth(SiteFramework framework, SiteAuthType authType) =>
      of(framework).supportedAuthTypes.contains(authType);

  /// 某框架下可选的认证方式（添加站点表单据此联动）。
  /// 该结构的推荐认证方式（表单默认项）。
  static SiteAuthType recommendedAuthType(SiteFramework framework) =>
      of(framework).recommendedAuthType;

  /// 可选认证方式里该结构的推荐项（若推荐项不被支持则退回第一个可选项）。
  static SiteAuthType defaultAuthTypeFor(
    SiteFramework framework, {
    bool cookieAllowed = true,
  }) {
    final List<SiteAuthType> allowed = authTypesFor(
      framework,
    ).where((SiteAuthType t) => cookieAllowed || t != SiteAuthType.cookie).toList(growable: false);
    final SiteAuthType recommended = recommendedAuthType(framework);
    if (allowed.contains(recommended)) return recommended;
    // 关闭 Cookie 抓取时，优先落到官方接口凭据（API Key / Passkey），再退回第一项。
    if (!cookieAllowed) {
      if (allowed.contains(SiteAuthType.apiKey)) return SiteAuthType.apiKey;
      if (allowed.contains(SiteAuthType.passkey)) return SiteAuthType.passkey;
    }
    if (allowed.isNotEmpty) return allowed.first;
    return recommended;
  }

  static List<SiteAuthType> authTypesFor(SiteFramework framework) {
    final Set<SiteAuthType> supported = of(framework).supportedAuthTypes;
    return SiteAuthType.values.where(supported.contains).toList(growable: false);
  }
}