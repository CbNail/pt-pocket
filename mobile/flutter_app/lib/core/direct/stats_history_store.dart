import '../storage/app_keys.dart';
import '../storage/prefs_store.dart';

/// 一条采样（每次成功抓取站点用户页时记录）。
class SiteSample {
  const SiteSample({
    required this.at,
    required this.uploadedBytes,
    required this.downloadedBytes,
    required this.bonus,
    required this.seedingCount,
  });

  final DateTime at;
  final int uploadedBytes;
  final int downloadedBytes;
  final int bonus;
  final int seedingCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': at.toIso8601String(),
        'up': uploadedBytes,
        'down': downloadedBytes,
        'bonus': bonus,
        'seed': seedingCount,
      };

  static SiteSample? fromJson(Map<String, dynamic> json) {
    final DateTime? at = DateTime.tryParse(json['at']?.toString() ?? '');
    if (at == null) return null;
    return SiteSample(
      at: at,
      uploadedBytes: (json['up'] as num?)?.toInt() ?? 0,
      downloadedBytes: (json['down'] as num?)?.toInt() ?? 0,
      bonus: (json['bonus'] as num?)?.toInt() ?? 0,
      seedingCount: (json['seed'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 今日增量（当日累计 − 前一自然日累计）。
class TodayDelta {
  const TodayDelta({required this.uploadedBytes, required this.downloadedBytes});

  final int uploadedBytes;
  final int downloadedBytes;
}

/// 时间轴上的一个自然日（PT-depiler「我的数据 · 时间轴」口径）。
class TrendPoint {
  const TrendPoint({
    required this.date,
    required this.uploadedBytes,
    required this.downloadedBytes,
    required this.bonus,
    this.uploadedDelta,
    this.downloadedDelta,
  });

  final String date;
  final int uploadedBytes;
  final int downloadedBytes;
  final int bonus;

  /// 相对前一自然日的增量；缺少基线时为 null（界面显示「基线不足」）。
  final int? uploadedDelta;
  final int? downloadedDelta;

  bool get hasBaseline => uploadedDelta != null && downloadedDelta != null;
}

/// 本地数据历史：为「今日增量」「综合时魔估算」「时间轴」提供基线。
///
/// 为什么需要它：参考实现（MoviePilot 的 PT 数据统计插件）的当日增量 = 当日累计 −
/// 前一自然日累计，时魔取自两次快照的差值；本 App 没有后端历史库，
/// 因此在本地按站点记录采样，缺基线时一律显示「基线不足」，不拿 0 冒充。
class StatsHistoryStore {
  StatsHistoryStore({required this.prefs});

  final PrefsStore prefs;

  /// 每站最多保留的采样条数（约 13 个月的日级采样）。
  static const int maxSamplesPerSite = 400;

  /// 记录一次采样（同一天会保留多条，用于估算时魔增速）。
  Future<void> record(
    String siteId, {
    required int uploadedBytes,
    required int downloadedBytes,
    required int bonus,
    required int seedingCount,
    DateTime? now,
  }) async {
    if (siteId.isEmpty) return;
    final DateTime at = now ?? DateTime.now();
    final List<SiteSample> samples = samplesOf(siteId).toList()
      ..add(
        SiteSample(
          at: at,
          uploadedBytes: uploadedBytes,
          downloadedBytes: downloadedBytes,
          bonus: bonus,
          seedingCount: seedingCount,
        ),
      );
    samples.sort((SiteSample a, SiteSample b) => a.at.compareTo(b.at));
    final DateTime cutoff = at.subtract(const Duration(days: 400));
    final List<SiteSample> trimmed = samples
        .where((SiteSample s) => s.at.isAfter(cutoff))
        .toList(growable: false);
    final List<SiteSample> kept = trimmed.length > maxSamplesPerSite
        ? trimmed.sublist(trimmed.length - maxSamplesPerSite)
        : trimmed;
    await _save(siteId, kept);
  }

  /// 某站的全部采样（按时间升序）。
  List<SiteSample> samplesOf(String siteId) {
    final Map<String, dynamic>? root = prefs.getJson(PrefKeys.statsHistory);
    if (root == null) return const <SiteSample>[];
    final Object? sites = root['sites'];
    if (sites is! Map<String, dynamic>) return const <SiteSample>[];
    final Object? raw = sites[siteId];
    if (raw is! List) return const <SiteSample>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(SiteSample.fromJson)
        .whereType<SiteSample>()
        .toList(growable: false);
  }

  /// 今日增量；缺少前一自然日基线时返回 null。
  TodayDelta? todayDelta(String siteId, {DateTime? now}) {
    final DateTime current = now ?? DateTime.now();
    final List<SiteSample> samples = samplesOf(siteId);
    final SiteSample? today = _lastSampleOfDay(samples, current);
    final SiteSample? yesterday = _lastSampleOfDay(samples, current.subtract(const Duration(days: 1)));
    if (today == null || yesterday == null) return null;
    // 累计值下降（站点重置 / 换号）时按 0 处理，不显示负数。
    return TodayDelta(
      uploadedBytes: (today.uploadedBytes - yesterday.uploadedBytes).clamp(0, 1 << 62),
      downloadedBytes: (today.downloadedBytes - yesterday.downloadedBytes).clamp(0, 1 << 62),
    );
  }

  /// 综合时魔估算：近 [window] 内两次间隔 ≥ [minGap] 的采样差值 ÷ 小时数。
  ///
  /// 这是**估算值**，与站点官方时魔口径可能不同，界面必须标注。
  double? hourlyBonusEstimate(
    String siteId, {
    DateTime? now,
    Duration window = const Duration(hours: 12),
    Duration minGap = const Duration(minutes: 30),
  }) {
    final DateTime current = now ?? DateTime.now();
    final DateTime from = current.subtract(window);
    final List<SiteSample> samples = samplesOf(siteId)
        .where((SiteSample s) => s.at.isAfter(from) && !s.at.isAfter(current))
        .toList(growable: false);
    if (samples.length < 2) return null;
    final SiteSample first = samples.first;
    final SiteSample last = samples.last;
    final double hours = last.at.difference(first.at).inMinutes / 60;
    if (hours < minGap.inMinutes / 60) return null;
    final int delta = last.bonus - first.bonus;
    if (delta <= 0) return null;
    return delta / hours;
  }

  /// 时间轴：近 [days] 天内有采样的自然日（按时间升序）。
  List<TrendPoint> trend(String siteId, {int days = 30, DateTime? now}) {
    final DateTime current = now ?? DateTime.now();
    final List<SiteSample> samples = samplesOf(siteId);
    final Map<String, SiteSample> lastOfDay = <String, SiteSample>{};
    for (final SiteSample sample in samples) {
      lastOfDay[_dayKey(sample.at)] = sample;
    }
    final List<String> keys = lastOfDay.keys.toList()..sort();
    final DateTime from = DateTime(current.year, current.month, current.day)
        .subtract(Duration(days: days - 1));
    final List<TrendPoint> points = <TrendPoint>[];
    SiteSample? previous;
    String? previousKey;
    for (final String key in keys) {
      final SiteSample sample = lastOfDay[key]!;
      if (sample.at.isBefore(from)) {
        previous = sample;
        previousKey = key;
        continue;
      }
      final bool consecutive = previous != null && _isNextDay(previousKey!, key);
      points.add(
        TrendPoint(
          date: key,
          uploadedBytes: sample.uploadedBytes,
          downloadedBytes: sample.downloadedBytes,
          bonus: sample.bonus,
          uploadedDelta:
              consecutive ? (sample.uploadedBytes - previous.uploadedBytes).clamp(0, 1 << 62) : null,
          downloadedDelta: consecutive
              ? (sample.downloadedBytes - previous.downloadedBytes).clamp(0, 1 << 62)
              : null,
        ),
      );
      previous = sample;
      previousKey = key;
    }
    return points.reversed.toList(growable: false);
  }

  /// 清空某站历史（删除站点时调用）。若该站没有历史则不做写入。
  Future<void> clearSite(String siteId) async {
    final Map<String, dynamic>? root = prefs.getJson(PrefKeys.statsHistory);
    if (root == null) return;
    final Object? sites = root['sites'];
    if (sites is! Map<String, dynamic>) return;
    if (!sites.containsKey(siteId)) return;
    sites.remove(siteId);
    await prefs.setJson(PrefKeys.statsHistory, root);
  }

  Future<void> _save(String siteId, List<SiteSample> samples) async {
    final Map<String, dynamic> root = prefs.getJson(PrefKeys.statsHistory) ??
        <String, dynamic>{'version': 1, 'sites': <String, dynamic>{}};
    final Object? existing = root['sites'];
    final Map<String, dynamic> sites = existing is Map<String, dynamic>
        ? existing
        : <String, dynamic>{};
    sites[siteId] = samples
        .map((SiteSample s) => s.toJson())
        .toList(growable: false);
    root['version'] = 1;
    root['sites'] = sites;
    await prefs.setJson(PrefKeys.statsHistory, root);
  }

  static SiteSample? _lastSampleOfDay(List<SiteSample> samples, DateTime day) {
    final String key = _dayKey(day);
    SiteSample? found;
    for (final SiteSample sample in samples) {
      if (_dayKey(sample.at) == key) found = sample;
    }
    return found;
  }

  static String _dayKey(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }

  static bool _isNextDay(String previous, String next) {
    final DateTime? a = DateTime.tryParse(previous);
    final DateTime? b = DateTime.tryParse(next);
    if (a == null || b == null) return false;
    return b.difference(a).inDays == 1;
  }
}