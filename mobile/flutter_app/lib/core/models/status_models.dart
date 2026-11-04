/// PT 个人数据、站点养老、监护事件与签到相关模型（跨站点归一化）。
///
/// 站点侧的数据采集（个人数据、保号规则、事件巡检、签到）统一由 NAS 后端完成，
/// 移动端只消费归一化结果并下发操作（规格书 §7.1）。
library;

import '../utils/format.dart';

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
    this.alternatives = const <String>[],
    this.satisfiedAlternative = '',
    this.note = '',
  });

  final double? minimumRatio;
  final int? minimumSeedingDays;
  final int? minimumUploadBytes;
  final bool requiresSignIn;

  /// 任选条件（满足其中**任一项**即可达标，参考插件对「任选条件」的口径）。
  final List<String> alternatives;

  /// 当前已命中的那个任选条件（为空表示都没满足）。
  final String satisfiedAlternative;

  final String note;

  /// 人类可读的要求摘要。
  String get summary {
    final List<String> parts = <String>[];
    if (minimumRatio != null) parts.add('分享率 ≥ ${minimumRatio!.toStringAsFixed(2)}');
    if (minimumSeedingDays != null) parts.add('做种 ≥ ${minimumSeedingDays!} 天');
    if (minimumUploadBytes != null) parts.add('上传量需达标');
    if (requiresSignIn) parts.add('需保持签到');
    if (parts.isEmpty) {
      if (alternatives.isNotEmpty) return '任选其一：${alternatives.join(' / ')}';
      return note.isEmpty ? '站点未提供明确的保号要求' : note;
    }
    return parts.join('；');
  }

  /// 任选条件的一句话说明（含当前是否已满足）。
  String get alternativesLabel {
    if (alternatives.isEmpty) return '';
    final String joined = alternatives.join(' / ');
    if (satisfiedAlternative.isEmpty) return '任选其一（当前均未满足）：$joined';
    return '任选其一（当前已满足「$satisfiedAlternative」）：$joined';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'minimumRatio': minimumRatio,
        'minimumSeedingDays': minimumSeedingDays,
        'minimumUploadBytes': minimumUploadBytes,
        'requiresSignIn': requiresSignIn,
        'alternatives': alternatives,
        'satisfiedAlternative': satisfiedAlternative,
        'note': note,
      };

  factory SiteCarePolicy.fromJson(Map<String, dynamic> json) => SiteCarePolicy(
        minimumRatio: (json['minimumRatio'] as num?)?.toDouble(),
        minimumSeedingDays: (json['minimumSeedingDays'] as num?)?.toInt(),
        minimumUploadBytes: (json['minimumUploadBytes'] as num?)?.toInt(),
        requiresSignIn: json['requiresSignIn'] as bool? ?? true,
        alternatives: (json['alternatives'] is List)
            ? (json['alternatives'] as List<dynamic>)
                .map((Object? item) => item.toString())
                .where((String item) => item.isNotEmpty)
                .toList(growable: false)
            : const <String>[],
        satisfiedAlternative: json['satisfiedAlternative']?.toString() ?? '',
        note: json['note'] as String? ?? '',
      );
}

/// 等级路线上的一个节点（养老进度分层展示用）。
class LevelStep {
  const LevelStep({
    required this.name,
    required this.requirement,
    required this.achieved,
    this.remaining = '',
  });

  final String name;
  final String requirement;
  final bool achieved;

  /// 未达成时「还差什么」；已达成时为空。
  final String remaining;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'requirement': requirement,
        'achieved': achieved,
        'remaining': remaining,
      };

  factory LevelStep.fromJson(Map<String, dynamic> json) => LevelStep(
        name: json['name']?.toString() ?? '',
        requirement: json['requirement']?.toString() ?? '',
        achieved: json['achieved'] as bool? ?? false,
        remaining: json['remaining']?.toString() ?? '',
      );
}

/// 站点数据刷新状态（站点页四态筛选的唯一口径）。
///
/// 判定由后端给出（参考 seedstats 的「数据过期 + 零做种」告警口径），App 只渲染：
/// - [refreshed]：本次刷新成功且数据在阈值内；
/// - [stale]：从未成功刷新，或上一次刷新已超过阈值；
/// - [failed]：最近一次刷新失败，[SiteStats.refreshMessage] 给出原因；
/// - [notLoggedIn]：凭据缺失 / 失效，需要重新登录或导入 Cookie。
enum SiteRefreshState {
  refreshed('已刷新'),
  stale('未刷新'),
  failed('失败'),
  notLoggedIn('未登录'),
  unknown('未检测');

  const SiteRefreshState(this.label);

  final String label;

  static SiteRefreshState fromName(String? value) {
    final String key = (value ?? '').replaceAll(RegExp(r'[^A-Za-z]'), '').toLowerCase();
    return switch (key) {
      'refreshed' || 'fresh' || 'ok' || 'success' || 'succeeded' => SiteRefreshState.refreshed,
      'stale' || 'never' || 'outdated' || 'expired' => SiteRefreshState.stale,
      'failed' || 'fail' || 'error' => SiteRefreshState.failed,
      'notloggedin' || 'unauthorized' || 'loginrequired' || 'expiredcredentials' =>
        SiteRefreshState.notLoggedIn,
      _ => SiteRefreshState.unknown,
    };
  }

  /// 面板筛选用到的四态（[unknown] 只在「全部」里出现）。
  static const List<SiteRefreshState> filterable = <SiteRefreshState>[
    SiteRefreshState.refreshed,
    SiteRefreshState.stale,
    SiteRefreshState.failed,
    SiteRefreshState.notLoggedIn,
  ];
}

/// 单个站点的数据统计与养老进度。
class SiteStats {
  const SiteStats({
    required this.siteId,
    required this.siteName,
    this.username = '',
    this.userClass = '',
    this.iconUrl = '',
    this.uploadedBytes = 0,
    this.downloadedBytes = 0,
    this.bonus = 0,
    this.hourlyBonus = 0,
    this.seedingCount = 0,
    this.leechingCount = 0,
    this.connections = 0,
    this.hrCount = 0,
    this.unreadMessages = 0,
    this.invites = 0,
    this.joinDate,
    this.ratioOverride,
    this.signedInToday = false,
    this.signInKnown = true,
    this.consecutiveSignInDays = 0,
    this.careState = CareState.unknown,
    this.careProgress = 0,
    this.policy,
    this.refreshState = SiteRefreshState.unknown,
    this.refreshMessage = '',
    this.refreshedAt,
    this.todayUploadedBytes = 0,
    this.todayDownloadedBytes = 0,
    this.todayBaselineAvailable = false,
    this.nextClass = '',
    this.nextClassRequirement = '',
    this.levelSteps = const <LevelStep>[],
    this.promotionNote = '',
    this.contractMet,
    this.contractNote = '',
  });

  final String siteId;
  final String siteName;
  final String username;
  final String userClass;

  /// 站点图标地址（后端可选下发）；为空时站点页用站点名首字生成图标。
  final String iconUrl;
  final int uploadedBytes;
  final int downloadedBytes;

  /// 魔力值 / 积分（各站口径不同，仅作展示）。
  final int bonus;

  /// 综合时魔：每小时魔力收益（站点口径不一，按后端估算展示）。
  final double hourlyBonus;
  final int seedingCount;
  final int leechingCount;

  /// 当前连接数（做种 + 下载中的连接总量）。
  final int connections;

  /// H&R / 保种契约未完成的数量；0 表示当前无 HR。
  final int hrCount;

  /// 未读邮件（站内信）数量。
  final int unreadMessages;

  /// 可邀请名额。
  final int invites;

  final DateTime? joinDate;

  /// 站点直接给出的分享率；缺省时由上传/下载计算。
  final double? ratioOverride;
  final bool signedInToday;

  /// 签到状态是否真的采集到了。
  ///
  /// 直连模式只读站点用户页，不解析签到页，因此签到状态是「未采集」——
  /// 这时不能显示「未签到」（那是另一种含义：采集到了并且没签）。
  final bool signInKnown;
  final int consecutiveSignInDays;
  final CareState careState;

  /// 保号进度（0–1）。
  final double careProgress;
  final SiteCarePolicy? policy;

  /// 数据刷新状态与最近一次刷新结论。
  final SiteRefreshState refreshState;
  final String refreshMessage;
  final DateTime? refreshedAt;

  /// 今日增量：当日累计 − 前一自然日累计（由后端计算）。
  final int todayUploadedBytes;
  final int todayDownloadedBytes;

  /// 是否有前一自然日的快照作为基线。**没有基线时今日增量不可计算**，
  /// 必须显示「基线不足」，而不是拿 0 冒充「今天没涨」。
  final bool todayBaselineAvailable;

  /// 等级路线：下一等级与达成条件。
  final String nextClass;
  final String nextClassRequirement;

  /// 完整等级路线（含每个等级的门槛与是否达成），供养老进度分层展示。
  final List<LevelStep> levelSteps;

  /// 等级规则口径说明（例如「按 NexusPHP 默认规则估算」）。
  final String promotionNote;

  /// 保种契约（H&R / 契约检查）是否达成；null 表示后端未提供该项。
  final bool? contractMet;
  final String contractNote;

  /// 今日上传文本；缺基线时明确写「基线不足」。
  String get todayUploadLabel =>
      todayBaselineAvailable ? formatBytes(todayUploadedBytes) : '基线不足';

  String get todayDownloadLabel =>
      todayBaselineAvailable ? formatBytes(todayDownloadedBytes) : '基线不足';

  /// 等级路线文本（空表示站点未提供等级信息）。
  String get classPlanLabel {
    if (nextClass.isEmpty) return '';
    if (nextClassRequirement.isEmpty) return '下一等级：$nextClass';
    return '下一等级：$nextClass（$nextClassRequirement）';
  }

  /// 契约达成文本；后端未提供时为「数据未提供」。
  String get contractLabel {
    if (contractMet == null) return '数据未提供';
    if (contractMet!) return '已达成';
    return hrCount > 0 ? '未达成（$hrCount 项）' : '未达成';
  }

  double? get ratio =>
      ratioOverride ?? (downloadedBytes > 0 ? uploadedBytes / downloadedBytes : null);

  String get ratioLabel {
    if (ratio == null) return '—';
    if (ratio!.isInfinite) return '∞';
    return ratio!.toStringAsFixed(2);
  }

  /// 站点图标回退用的首字（中文取第一个字，英文取首字母大写）。
  String get iconLetter {
    final String name = siteName.trim();
    if (name.isEmpty) return '?';
    return name.substring(0, 1).toUpperCase();
  }

  String get hourlyBonusLabel =>
      hourlyBonus > 0 ? '${hourlyBonus.toStringAsFixed(2)}/h' : '—';

  String get hrLabel => hrCount > 0 ? '$hrCount 项' : '无';

  /// 签到情况：今日已签 + 连续天数；未采集时明确写「未采集」。
  String get signInLabel {
    if (!signInKnown) return '未采集';
    if (!signedInToday) return '未签';
    return consecutiveSignInDays > 0 ? '已签 · 连续 $consecutiveSignInDays 天' : '已签';
  }

  /// 签到状态一句话（页面卡片用，避免把「未采集」渲染成「未签到」）。
  String get signInStatusLabel {
    if (!signInKnown) return '签到状态未采集';
    if (!signedInToday) return '今日未签到';
    return consecutiveSignInDays > 0 ? '今日已签到（连续 $consecutiveSignInDays 天）' : '今日已签到';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'siteId': siteId,
        'siteName': siteName,
        'username': username,
        'userClass': userClass,
        'iconUrl': iconUrl,
        'uploadedBytes': uploadedBytes,
        'downloadedBytes': downloadedBytes,
        'bonus': bonus,
        'hourlyBonus': hourlyBonus,
        'seedingCount': seedingCount,
        'leechingCount': leechingCount,
        'connections': connections,
        'hrCount': hrCount,
        'unreadMessages': unreadMessages,
        'invites': invites,
        'joinDate': joinDate?.toIso8601String(),
        'ratioOverride': ratioOverride,
        'signedInToday': signedInToday,
        'signInKnown': signInKnown,
        'consecutiveSignInDays': consecutiveSignInDays,
        'careState': careState.name,
        'careProgress': careProgress,
        'policy': policy?.toJson(),
        'refreshState': refreshState.name,
        'refreshMessage': refreshMessage,
        'refreshedAt': refreshedAt?.toIso8601String(),
        'todayUploadedBytes': todayUploadedBytes,
        'todayDownloadedBytes': todayDownloadedBytes,
        'todayBaselineAvailable': todayBaselineAvailable,
        'nextClass': nextClass,
        'nextClassRequirement': nextClassRequirement,
        'levelSteps': levelSteps.map((LevelStep s) => s.toJson()).toList(growable: false),
        'promotionNote': promotionNote,
        'contractMet': contractMet,
        'contractNote': contractNote,
      };

  /// 解析后端返回；缺失字段一律按「未提供」处理，不填 0 冒充真实数据。
  factory SiteStats.fromJson(Map<String, dynamic> json) => SiteStats(
        siteId: json['siteId']?.toString() ?? json['id']?.toString() ?? '',
        siteName: json['siteName']?.toString() ?? json['name']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        userClass: json['userClass']?.toString() ?? json['class']?.toString() ?? '',
        iconUrl: json['iconUrl']?.toString() ?? json['icon']?.toString() ?? '',
        uploadedBytes: _int(json['uploadedBytes'] ?? json['uploaded']),
        downloadedBytes: _int(json['downloadedBytes'] ?? json['downloaded']),
        bonus: _int(json['bonus'] ?? json['points']),
        hourlyBonus: _double(json['hourlyBonus'] ?? json['hourlyBonusPoints'] ?? json['bonusPerHour']),
        seedingCount: _int(json['seedingCount'] ?? json['seeding']),
        leechingCount: _int(json['leechingCount'] ?? json['leeching']),
        connections: _int(json['connections'] ?? json['peers']),
        hrCount: _int(json['hrCount'] ?? json['hr'] ?? json['hitAndRun']),
        unreadMessages: _int(json['unreadMessages'] ?? json['messages'] ?? json['mail']),
        invites: _int(json['invites'] ?? json['inviteCount']),
        joinDate: _date(json['joinDate'] ?? json['registeredAt']),
        ratioOverride: (json['ratio'] as num?)?.toDouble(),
        signedInToday: json['signedInToday'] as bool? ?? false,
        signInKnown: json['signInKnown'] as bool? ?? true,
        consecutiveSignInDays: _int(json['consecutiveSignInDays']),
        careState: CareState.fromName(json['careState']?.toString()),
        careProgress: (json['careProgress'] as num?)?.toDouble() ?? 0,
        policy: json['policy'] is Map<String, dynamic>
            ? SiteCarePolicy.fromJson(json['policy'] as Map<String, dynamic>)
            : null,
        refreshState: SiteRefreshState.fromName(
          json['refreshState']?.toString() ?? json['state']?.toString(),
        ),
        refreshMessage: json['refreshMessage']?.toString() ?? json['errMsg']?.toString() ?? '',
        refreshedAt: _date(json['refreshedAt'] ?? json['updatedAt']),
        todayUploadedBytes: _int(json['todayUploadedBytes'] ?? json['todayUploaded']),
        todayDownloadedBytes: _int(json['todayDownloadedBytes'] ?? json['todayDownloaded']),
        // 缺基线时后端给 false / 缺省；只有显式 true 才算有基线。
        todayBaselineAvailable: json['todayBaselineAvailable'] as bool? ?? false,
        nextClass: json['nextClass']?.toString() ?? '',
        nextClassRequirement: json['nextClassRequirement']?.toString() ?? '',
        levelSteps: (json['levelSteps'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(LevelStep.fromJson)
            .toList(growable: false),
        promotionNote: json['promotionNote']?.toString() ?? '',
        contractMet: json['contractMet'] as bool?,
        contractNote: json['contractNote']?.toString() ?? '',
      );
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// 个人 PT 数据快照（数据统计与历程）。
class PtDataSnapshot {
  const PtDataSnapshot({
    required this.sites,
    this.generatedAt,
    this.notice = '',
    this.todayUploadedBytes,
    this.todayDownloadedBytes,
    this.todayBaselineAvailable,
  });

  final List<SiteStats> sites;
  final DateTime? generatedAt;
  final String notice;

  /// 今日总量增量。后端给了就用后端的；没给则按各站增量求和（口径一致）。
  final int? todayUploadedBytes;
  final int? todayDownloadedBytes;

  /// 是否有基线；后端未给时按「所有站点都有基线」推断。
  final bool? todayBaselineAvailable;

  bool get hasTodayBaseline =>
      todayBaselineAvailable ?? (sites.isNotEmpty && sites.every((SiteStats s) => s.todayBaselineAvailable));

  int get todayUploaded =>
      todayUploadedBytes ?? sites.fold(0, (int sum, SiteStats s) => sum + s.todayUploadedBytes);

  int get todayDownloaded =>
      todayDownloadedBytes ?? sites.fold(0, (int sum, SiteStats s) => sum + s.todayDownloadedBytes);

  /// 今日上传文本；缺基线时写「基线不足」（不拿 0 冒充）。
  String get todayUploadLabel => hasTodayBaseline ? formatBytes(todayUploaded) : '基线不足';

  String get todayDownloadLabel => hasTodayBaseline ? formatBytes(todayDownloaded) : '基线不足';

  int get siteCount => sites.length;

  int get totalUploaded =>
      sites.fold(0, (int sum, SiteStats s) => sum + s.uploadedBytes);

  int get totalDownloaded =>
      sites.fold(0, (int sum, SiteStats s) => sum + s.downloadedBytes);

  int get totalBonus => sites.fold(0, (int sum, SiteStats s) => sum + s.bonus);

  int get totalSeeding => sites.fold(0, (int sum, SiteStats s) => sum + s.seedingCount);

  double? get overallRatio =>
      totalDownloaded > 0 ? totalUploaded / totalDownloaded : null;

  /// 已确认「今日已签到」的站点数（未采集签到的站点不计入）。
  int get signedInCount =>
      sites.where((SiteStats s) => s.signInKnown && s.signedInToday).length;

  /// 真的采集到签到状态的站点数；为 0 时界面显示「未采集」。
  int get signInKnownCount => sites.where((SiteStats s) => s.signInKnown).length;

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
      todayUploadedBytes: json['todayUploadedBytes'] == null
          ? null
          : _int(json['todayUploadedBytes'] ?? json['todayUploaded']),
      todayDownloadedBytes: json['todayDownloadedBytes'] == null
          ? null
          : _int(json['todayDownloadedBytes'] ?? json['todayDownloaded']),
      todayBaselineAvailable: json['todayBaselineAvailable'] as bool?,
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
/// 签到方式：参考实现把站点分成「签到站点」与「仅模拟登录站点」两类
/// （有些站不定义签到，只能用模拟登录维持账号活跃），移动端按同一口径区分。
enum SignInMode {
  both('签到 + 模拟登录', 'both'),
  signin('仅签到', 'signin'),
  login('仅模拟登录', 'login');

  const SignInMode(this.label, this.apiValue);

  final String label;
  final String apiValue;

  static SignInMode fromName(String? value) => values.firstWhere(
        (SignInMode m) => m.apiValue == value,
        orElse: () => SignInMode.both,
      );
}

/// 单站动作类型（结果里区分这次是签到还是模拟登录）。
enum SignInAction {
  signin('签到'),
  login('模拟登录');

  const SignInAction(this.label);

  final String label;

  static SignInAction fromName(String? value) =>
      value == 'login' ? SignInAction.login : SignInAction.signin;
}

class SignInRecord {
  const SignInRecord({
    required this.siteId,
    required this.siteName,
    required this.success,
    this.message = '',
    this.signedAt,
    this.action = SignInAction.signin,
  });

  final String siteId;
  final String siteName;
  final bool success;
  final String message;
  final DateTime? signedAt;

  /// 这次做的是签到还是模拟登录。
  final SignInAction action;

  factory SignInRecord.fromJson(Map<String, dynamic> json) => SignInRecord(
        siteId: json['siteId']?.toString() ?? '',
        siteName: json['siteName']?.toString() ?? '',
        success: json['success'] as bool? ?? false,
        message: json['message']?.toString() ?? '',
        signedAt: _date(json['signedAt'] ?? json['time']),
        action: SignInAction.fromName(
          json['action']?.toString() ?? json['mode']?.toString() ?? json['type']?.toString(),
        ),
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