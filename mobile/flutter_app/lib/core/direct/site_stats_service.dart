import '../models/pt_site.dart';
import '../models/status_models.dart';
import 'care_rules.dart';
import 'nexusphp_client.dart';
import 'stats_history_store.dart';

/// 站点数据 → [SiteStats] 组装（直连口径）。
///
/// 数据链：
/// 1. [NexusPhpClient] 直连站点用户页，解析上传 / 下载 / 分享率 / 魔力 / 做种 / 邀请 / 邮件 / H&R / 注册时间；
/// 2. [StatsHistoryStore] 本地记录采样，算「今日增量」（缺前一自然日基线 → 基线不足）与「综合时魔估算」；
/// 3. [CareRules] 按等级路线给出下一等级、还差多少与保号进度。
///
/// 口径纪律：站点页没给出的字段一律标「未采集 / 数据未提供」，不用 0 冒充；
/// 签到状态不解析签到页，因此明确写「未采集」（[SiteStats.signInKnown] = false）。
class SiteStatsService {
  SiteStatsService({required this.client, required this.history});

  final NexusPhpClient client;
  final StatsHistoryStore history;

  /// 抓取并组装单站数据；失败时返回带明确原因的 [SiteStats]（不抛异常，便于批量聚合）。
  Future<SiteStats> fetchSite(
    PtSite site, {
    Map<String, dynamic>? credential,
    DateTime? now,
  }) async {
    try {
      final SiteUserSnapshot snapshot = await client.fetchUserSnapshot(site, credential: credential);
      await _recordSample(site.id, snapshot, now: now);
      return build(site: site, snapshot: snapshot, now: now);
    } on SiteFetchException catch (error) {
      return failure(site: site, error: error);
    } catch (error) {
      return failure(
        site: site,
        error: SiteFetchException(
          kind: SiteFetchFailureKind.unknown,
          message: '${site.name} 数据抓取失败：$error',
        ),
      );
    }
  }

  /// 由已解析的快照组装 [SiteStats]（纯逻辑，便于单测）。
  SiteStats build({
    required PtSite site,
    required SiteUserSnapshot snapshot,
    DateTime? now,
  }) {
    final DateTime current = now ?? DateTime.now();
    final TodayDelta? delta = history.todayDelta(site.id, now: current);
    final double? hourly = history.hourlyBonusEstimate(site.id, now: current);
    final CareEvaluation care = CareRules.evaluate(
      userClass: snapshot.userClass,
      uploadedBytes: snapshot.uploadedBytes,
      ratio: snapshot.ratio,
      infiniteRatio: snapshot.infiniteRatio,
      joinDate: snapshot.joinDate,
      now: current,
    );

    final List<String> notes = <String>[];
    if (snapshot.missing.isNotEmpty) {
      notes.add('站点页未提供：${snapshot.missing.join('、')}');
    }
    notes.add('签到状态未采集（直连模式不解析签到页）');
    if (delta == null) notes.add('今日增量缺少前一自然日基线');

    return SiteStats(
      siteId: site.id,
      siteName: site.name,
      username: snapshot.username,
      userClass: care.currentClass.isNotEmpty ? care.currentClass : snapshot.userClass,
      uploadedBytes: snapshot.uploadedBytes ?? 0,
      downloadedBytes: snapshot.downloadedBytes ?? 0,
      bonus: snapshot.bonus ?? 0,
      hourlyBonus: hourly ?? 0,
      seedingCount: snapshot.seedingCount ?? 0,
      leechingCount: snapshot.leechingCount ?? 0,
      // 连接数需要站点用户详情页（BT 客户端列表），直连模式暂不采集。
      connections: 0,
      hrCount: snapshot.hrCount ?? 0,
      unreadMessages: snapshot.unreadMessages ?? 0,
      invites: snapshot.invites ?? 0,
      joinDate: snapshot.joinDate,
      ratioOverride:
          snapshot.infiniteRatio ? double.infinity : snapshot.effectiveRatio,
      signedInToday: false,
      signInKnown: false,
      consecutiveSignInDays: 0,
      careState: care.careState,
      careProgress: care.careProgress,
      policy: care.policy,
      refreshState: SiteRefreshState.refreshed,
      refreshMessage: notes.join('；'),
      refreshedAt: snapshot.fetchedAt ?? current,
      todayUploadedBytes: delta?.uploadedBytes ?? 0,
      todayDownloadedBytes: delta?.downloadedBytes ?? 0,
      todayBaselineAvailable: delta != null,
      nextClass: care.nextClass,
      nextClassRequirement: care.nextClassRequirement,
      levelSteps: care.steps,
      promotionNote: care.note,
      contractMet: snapshot.hrCount == null ? null : snapshot.hrCount == 0,
      contractNote: snapshot.hrSummary.isEmpty ? '' : '站点用户页 H&R：${snapshot.hrSummary}',
    );
  }

  /// 抓取失败时的呈现：保留站点身份，写清失败原因与所属分类。
  SiteStats failure({required PtSite site, required SiteFetchException error}) {
    final bool credentialIssue = error.kind == SiteFetchFailureKind.missingCredential ||
        error.kind == SiteFetchFailureKind.unauthorized ||
        error.kind == SiteFetchFailureKind.rateLimited;
    return SiteStats(
      siteId: site.id,
      siteName: site.name,
      refreshState:
          credentialIssue ? SiteRefreshState.notLoggedIn : SiteRefreshState.failed,
      refreshMessage: '${error.kind.label}：${error.message}',
      signedInToday: false,
      signInKnown: false,
    );
  }

  Future<void> _recordSample(
    String siteId,
    SiteUserSnapshot snapshot, {
    DateTime? now,
  }) async {
    if (!snapshot.hasCoreNumbers) return;
    await history.record(
      siteId,
      uploadedBytes: snapshot.uploadedBytes ?? 0,
      downloadedBytes: snapshot.downloadedBytes ?? 0,
      bonus: snapshot.bonus ?? 0,
      seedingCount: snapshot.seedingCount ?? 0,
      now: now,
    );
  }
}