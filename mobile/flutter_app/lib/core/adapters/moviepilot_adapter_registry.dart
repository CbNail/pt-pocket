import '../models/moviepilot.dart';

/// MoviePilot 适配定义（客户端侧能力声明）。
///
/// 需求 4：先按 v2 打通，v3 出正式版后再补适配层。
/// 适配器实现位于 NAS 后端（`backend/app/adapters/moviepilot/`），
/// 这里只声明版本能力，供 App 表单联动与用户提示使用。
class MpAdapterDescriptor {
  const MpAdapterDescriptor({
    required this.version,
    required this.adapterId,
    required this.supportsSearch,
    required this.supportsPush,
    required this.note,
  });

  final MpVersion version;

  /// 服务端适配器注册名。
  final String adapterId;

  final bool supportsSearch;
  final bool supportsPush;
  final String note;
}

/// 内置 MoviePilot 适配注册表。
abstract final class MoviePilotAdapterRegistry {
  /// 当前默认接入版本（v2 已打通）。
  static const MpVersion defaultVersion = MpVersion.v2;

  static const List<MpAdapterDescriptor> descriptors = <MpAdapterDescriptor>[
    MpAdapterDescriptor(
      version: MpVersion.v2,
      adapterId: 'moviepilot_v2',
      supportsSearch: true,
      supportsPush: true,
      note: '按 MoviePilot v2 的搜索与资源接口对接，已可用于搜索增强与推送。',
    ),
    MpAdapterDescriptor(
      version: MpVersion.v3,
      adapterId: 'moviepilot_v3',
      supportsSearch: false,
      supportsPush: false,
      note: 'v3 适配层已预留：当前只登记实例配置，等 v3 正式版发布后补齐实现即可启用，无需改动调用方。',
    ),
  ];

  static MpAdapterDescriptor of(MpVersion version) => descriptors.firstWhere(
        (MpAdapterDescriptor d) => d.version == version,
        orElse: () => descriptors.first,
      );

  /// 可作为搜索增强来源的实例（启用且适配器支持搜索）。
  static bool canEnhanceSearch(MpInstance instance) =>
      instance.enabled && of(instance.version).supportsSearch;

  /// 从实例列表中挑出实际参与搜索增强的实例 id。
  static List<String> enhanceInstanceIds(List<MpInstance> instances) => instances
      .where(canEnhanceSearch)
      .where((MpInstance i) => i.searchEnhance)
      .map((MpInstance i) => i.id)
      .toList(growable: false);
}