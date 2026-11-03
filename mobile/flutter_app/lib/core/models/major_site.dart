/// 首页「重点站点收集进度」的数据模型。
///
/// 12 大站点清单作为用户可配置项维护（不同用户的重点站点不同），
/// 默认给出 12 个空槽位，由站点模块在配置完成后回填名称与进度。
library;

/// 单个重点站点的收集进度。
class MajorSiteProgress {
  const MajorSiteProgress({
    required this.slot,
    this.siteId,
    this.name,
    this.isCollected = false,
    this.progress,
  });

  /// 槽位序号（0-based）。
  final int slot;

  /// 已配置站点的唯一标识；为空表示该槽位尚未配置。
  final String? siteId;

  /// 展示名称；未配置时为 null。
  final String? name;

  /// 是否已收集该站点（已拥有账号并通过连接测试）。
  final bool isCollected;

  /// 保号/收集进度 0.0–1.0；null 表示无可用指标（需手动录入）。
  final double? progress;

  bool get isConfigured => siteId != null && (name?.isNotEmpty ?? false);

  MajorSiteProgress copyWith({
    int? slot,
    String? siteId,
    String? name,
    bool? isCollected,
    double? progress,
  }) =>
      MajorSiteProgress(
        slot: slot ?? this.slot,
        siteId: siteId ?? this.siteId,
        name: name ?? this.name,
        isCollected: isCollected ?? this.isCollected,
        progress: progress ?? this.progress,
      );

  /// 生成 12 个未配置槽位。
  static List<MajorSiteProgress> emptySlots({int count = 12}) =>
      List<MajorSiteProgress>.generate(
        count,
        (int index) => MajorSiteProgress(slot: index),
      );
}