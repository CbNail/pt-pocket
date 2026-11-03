/// PT 个人数据、站点养老、监护事件与签到相关模型（跨站点归一化）。
///
/// 站点侧的数据采集（个人数据、保号规则、事件巡检、签到）统一由 NAS 后端完成，
/// 移动端只消费归一化结果并下发操作（规格书 §7.1）。
library;

/// 站点养老（保号）状态。
enum CareState {
  healthy('健康'),
  attention('需关注'),
  atRisk('有掉级风险'),
  unknown('未采集');

  const CareState(this.label);

  final String label;

  static CareState fromName(String? value) => values.firstWhere(
        (CareState c) => c.name == value,
        orElse: () => CareState.unknown,
      );
}

/// 站点养老（保号）要求。
class SiteCarePolicy {
  const SiteCarePolicy({
    this.minimumRatio,
    this.minimumSeedingDays,
    this.minimumUploadBytes,
    this.requiresSignIn = true,
    this.note = '',
  });

  final double? minimumRatio;
  final int? minimumSeedingDays;
  final int? minimumUploadBytes;
  final bool requiresSignIn;
  final String note;

  /// 人类可读的要求摘要。
  String get summary {
    final List<String> parts = <String>[];
    if (minimumRatio != null) parts.add('分享率 ≥ ${minimumRatio!.toStringAsFixed(2)}');
    if (minimumSeedingDays != null) parts.add('做种 ≥ ${minimumSeedingDays!} 天');
    if (minimumUploadBytes != null) parts.add('上传量需达标');
    if (requiresSignIn) parts.add('需保持签到');
    if (parts.isEmpty) return note.isEmpty ? '站点未提供明确的保号要求' : note;
    return parts.join('；');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'minimumRatio': minimumRatio,
        'minimumSeedingDays': minimumSeedingDays,
        'minimumUploadBytes': minimumUploadBytes,
        'requiresSignIn': requiresSignIn,
        'note': note,
      };

  factory SiteCarePolicy.fromJson(Map<String, dynamic> json) => SiteCarePolicy(
        minimumRatio: (json['minimumRatio'] as num?)?.toDouble(),
        minimumSeedingDays: (json['minimumSeedingDays'] as num?)?.toInt(),
        minimumUploadBytes: (json['minimumUploadBytes'] as num?)?.toInt(),
        requiresSignIn: json['requiresSignIn'] as bool? ?? true,
        note: json['note'] as String? ?? '',
      );
}

/// 单个站点的数据统计与养老进度。
class SiteStats {
  const SiteStats({
    required this.siteId,
    required this.siteName,
    this.username = '',
    this.userClass = '',
    this.uploadedBytes = 0,
    this.downloadedBytes = 0,
    this.bonus = 0,
    this.seedingCount = 0,
    this.leechingCount = 0,
    this.joinDate,
    this.ratioOverride,
    this.signedInToday = false,
    this.consecutiveSignInDays = 0,
    this.careState = CareState.unknown,
    this.careProgress = 0,
    this.policy,
  });

  final String siteId;
  final String siteName;
  final String username;
  final String userClass;
  final int uploadedBytes;
  final int downloadedBytes;

  /// 魔力值 / 积分（各站口径不同，仅作展示）。
  final int bonus;
  final int seedingCount;
  final int leechingCount;
  final DateTime? joinDate;

  /// 站点直接给出的分享率；缺省时由上传/下载计算。
  final double? ratioOverride;
  final bool signedInToday;
  final int consecutiveSignInDays;
  final CareState careState;

  /// 保号进度（0–1）。
  final double careProgress;
  final SiteCarePolicy? policy;

  double? get ratio =>
      ratioOverride ?? (downloadedBytes > 0 ? uploadedBytes / downloadedBytes : null);

  String get ratioLabel => ratio == null ? '—' : ratio!.toStringAsFixed(2);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'siteId': siteId,
        'siteName': siteName,
        'username': username,
        'userClass': userClass,
        'uploadedBytes': uploadedBytes,
        'downloadedBytes': downloadedBytes,
        'bonus': bonus,
        'seedingCount': seedingCount,
        'leechingCount': leechingCount,
        'joinDate': joinDate?.toIso8601String(),
        'ratioOverride': ratioOverride,
        'signedInToday': signedInToday,
        'consecutiveSignInDays': consecutiveSignInDays,
        'careState': careState.name,
        'careProgress': careProgress,
        'policy': policy?.toJson(),
      };

  factory SiteStats.fromJson(Map<String, dynamic> json) => SiteStats(
        siteId: json['siteId']?.toString() ?? json['id']?.toString() ?? '',
        siteName: json['siteName']?.toString() ?? json['name']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        userClass: json['userClass']?.toString() ?? json['class']?.toString() ?? '',
        uploadedBytes: _int(json['uploadedBytes'] ?? json['uploaded']),
        downloadedBytes: _int(json['downloadedBytes'] ?? json['downloaded']),
        bonus: _int(json['bonus'] ?? json['points']),
        seedingCount: _int(json['seedingCount'] ?? json['seeding']),
        leechingCount: _int(json['leechingCount'] ?? json['leeching']),
        joinDate: _date(json['joinDate'] ?? json['registeredAt']),
        ratioOverride: (json['ratio'] as num?)?.toDouble(),
        signedInToday: json['signedInToday'] as bool? ?? false,
        consecutiveSignInDays: _int(json['consecutiveSignInDays']),
        careState: CareState.fromName(json['careState']?.toString()),
        careProgress: (json['careProgress'] as num?)?.toDouble() ?? 0,
        policy: json['policy'] is Map<String, dynamic>
            ? SiteCarePolicy.fromJson(json['policy'] as Map<String, dynamic>)
            : null,
      );
}

/// 个人 PT 数据快照（数据统计与历程）。
class PtDataSnapshot {
  const PtDataSnapshot({required this.sites, this.generatedAt, this.notice = ''});

  final List<SiteStats> sites;
  final DateTime? generatedAt;
  final String notice;

  int get siteCount => sites.length;

  int get totalUploaded =>
      sites.fold(0, (int sum, SiteStats s) => sum + s.uploadedBytes);

  int get totalDownloaded =>
      sites.fold(0, (int sum, SiteStats s) => sum + s.downloadedBytes);

  int get totalBonus => sites.fold(0, (int sum, SiteStats s) => sum + s.bonus);

  int get totalSeeding => sites.fold(0, (int sum, SiteStats s) => sum + s.seedingCount);

  double? get overallRatio =>
      totalDownloaded > 0 ? totalUploaded / totalDownloaded : null;

  int get signedInCount => sites.where((SiteStats s) => s.signedInToday).length;

  factory PtDataSnapshot.fromJson(Map<String, dynamic> json) {
    final Object? rawSites = json['sites'] ?? json['items'];
    final List<SiteStats> sites = rawSites is List
        ? rawSites
            .whereType<Map<String, dynamic>>()
            .map(SiteStats.fromJson)
            .toList(growable: false)
        : const <SiteStats>[];
    return PtDataSnapshot(
      sites: sites,
      generatedAt: _date(json['generatedAt']),
      notice: json['notice']?.toString() ?? '',
    );
  }
}

/// 监护事件类型。
enum MonitorEventType {
  danger('站点病危'),
  anniversary('站庆'),
  maintenance('维护'),
  signInFailure('签到失败'),
  warning('风险提示'),
  other('其它');

  const MonitorEventType(this.label);

  final String label;

  static MonitorEventType fromName(String? value) => values.firstWhere(
        (MonitorEventType t) => t.name == value,
        orElse: () => MonitorEventType.other,
      );
}

/// 事件严重程度。
enum MonitorSeverity {
  info('提示'),
  warning('需关注'),
  critical('紧急');

  const MonitorSeverity(this.label);

  final String label;

  static MonitorSeverity fromName(String? value) => values.firstWhere(
        (MonitorSeverity s) => s.name == value,
        orElse: () => MonitorSeverity.info,
      );
}

/// 监护事件（病危 / 站庆 / 维护 / 签到失败等）。
class MonitorEvent {
  const MonitorEvent({
    required this.id,
    required this.title,
    this.siteId = '',
    this.siteName = '',
    this.type = MonitorEventType.other,
    this.severity = MonitorSeverity.info,
    this.description = '',
    this.occurredAt,
    this.link = '',
  });

  final String id;
  final String title;
  final String siteId;
  final String siteName;
  final MonitorEventType type;
  final MonitorSeverity severity;
  final String description;
  final DateTime? occurredAt;
  final String link;

  factory MonitorEvent.fromJson(Map<String, dynamic> json) => MonitorEvent(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? json['name']?.toString() ?? '',
        siteId: json['siteId']?.toString() ?? '',
        siteName: json['siteName']?.toString() ?? '',
        type: MonitorEventType.fromName(json['type']?.toString()),
        severity: MonitorSeverity.fromName(json['severity']?.toString()),
        description: json['description']?.toString() ?? '',
        occurredAt: _date(json['occurredAt'] ?? json['time']),
        link: json['link']?.toString() ?? '',
      );
}

/// 单站签到记录。
class SignInRecord {
  const SignInRecord({
    required this.siteId,
    required this.siteName,
    required this.success,
    this.message = '',
    this.signedAt,
  });

  final String siteId;
  final String siteName;
  final bool success;
  final String message;
  final DateTime? signedAt;

  factory SignInRecord.fromJson(Map<String, dynamic> json) => SignInRecord(
        siteId: json['siteId']?.toString() ?? '',
        siteName: json['siteName']?.toString() ?? '',
        success: json['success'] as bool? ?? false,
        message: json['message']?.toString() ?? '',
        signedAt: _date(json['signedAt'] ?? json['time']),
      );
}

/// 一次签到（批量或单站）的结果。
class SignInRunResult {
  const SignInRunResult({required this.records, this.ranAt, this.notice = ''});

  final List<SignInRecord> records;
  final DateTime? ranAt;
  final String notice;

  int get successCount => records.where((SignInRecord r) => r.success).length;

  int get failedCount => records.where((SignInRecord r) => !r.success).length;

  List<SignInRecord> get failedSites =>
      records.where((SignInRecord r) => !r.success).toList(growable: false);

  factory SignInRunResult.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['records'] ?? json['items'];
    final List<SignInRecord> records = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(SignInRecord.fromJson)
            .toList(growable: false)
        : const <SignInRecord>[];
    return SignInRunResult(
      records: records,
      ranAt: _date(json['ranAt']),
      notice: json['notice']?.toString() ?? '',
    );
  }
}

/// 主页 12 大站点的槽位配置（清单由用户自行配置，不内置臆造站点）。
class MajorSiteSlot {
  const MajorSiteSlot({required this.slot, this.name = '', this.siteId = '', this.note = ''});

  final int slot;
  final String name;
  final String siteId;
  final String note;

  bool get isConfigured => name.trim().isNotEmpty || siteId.trim().isNotEmpty;

  MajorSiteSlot copyWith({int? slot, String? name, String? siteId, String? note}) => MajorSiteSlot(
        slot: slot ?? this.slot,
        name: name ?? this.name,
        siteId: siteId ?? this.siteId,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'slot': slot,
        'name': name,
        'siteId': siteId,
        'note': note,
      };

  factory MajorSiteSlot.fromJson(Map<String, dynamic> json) => MajorSiteSlot(
        slot: _int(json['slot']),
        name: json['name']?.toString() ?? '',
        siteId: json['siteId']?.toString() ?? '',
        note: json['note']?.toString() ?? '',
      );

  /// 默认 12 个空槽位。
  static List<MajorSiteSlot> defaults({int count = 12}) =>
      List<MajorSiteSlot>.generate(count, (int index) => MajorSiteSlot(slot: index + 1));
}

int _int(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

DateTime? _date(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is num) {
    // 兼容服务端返回的秒级时间戳。
    return DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000, isUtc: true).toLocal();
  }
  return null;
}