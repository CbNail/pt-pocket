import '../models/pt_site.dart';

/// 单个站点适配定义（本产品自研适配器的能力声明，不是对第三方站点的承诺）。
///
/// 服务端适配器按 [adapterId] 注册；移动端只用它做表单联动与能力提示。
class SiteAdapterDescriptor {
  const SiteAdapterDescriptor({
    required this.framework,
    required this.adapterId,
    required this.supportedAuthTypes,
    this.supportsSearch = true,
    this.supportsSignIn = true,
    this.supportsUserProfile = true,
    this.note = '',
  });

  final SiteFramework framework;

  /// 服务端适配器注册名。
  final String adapterId;

  final Set<SiteAuthType> supportedAuthTypes;
  final bool supportsSearch;
  final bool supportsSignIn;
  final bool supportsUserProfile;
  final String note;
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
      note: 'NexusPHP 结构适配定义：Cookie 维护登录态，站点 API 用于搜索与个人数据。',
    ),
    SiteAdapterDescriptor(
      framework: SiteFramework.unit3d,
      adapterId: 'unit3d',
      supportedAuthTypes: <SiteAuthType>{SiteAuthType.cookie, SiteAuthType.apiKey},
      note: 'Unit3D 结构适配定义：搜索与个人数据依赖站点 API 密钥。',
    ),
    SiteAdapterDescriptor(
      framework: SiteFramework.gazelle,
      adapterId: 'gazelle',
      supportedAuthTypes: <SiteAuthType>{SiteAuthType.cookie, SiteAuthType.apiKey},
      note: 'Gazelle 结构适配定义。',
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
  static List<SiteAuthType> authTypesFor(SiteFramework framework) {
    final Set<SiteAuthType> supported = of(framework).supportedAuthTypes;
    return SiteAuthType.values.where(supported.contains).toList(growable: false);
  }
}