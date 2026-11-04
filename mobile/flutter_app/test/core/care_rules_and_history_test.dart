// 养老进度规则与本地历史测试（需求 2 / 3）：
// - 等级路线：当前等级、下一等级、还差多少（天数 / 上传 / 分享率）；
// - 保号状态：达标 / 需关注 / 有风险 / 数据不足；
// - 今日增量必须有前一自然日基线，缺基线时不返回数字；
// - 综合时魔按两次采样差值估算；时间轴按自然日给出增量与基线标记。

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/direct/care_rules.dart';
import 'package:pt_pocket/core/direct/stats_history_store.dart';
import 'package:pt_pocket/core/models/status_models.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('等级路线与保号进度', () {
    final DateTime now = DateTime(2026, 11, 4, 12);

    test('默认等级路线为 NexusPHP 常用门槛', () {
      expect(nexusPhpDefaultLadder.length, 8);
      expect(nexusPhpDefaultLadder.first.name, 'Power User');
      expect(nexusPhpDefaultLadder.first.weeks, 4);
      expect(nexusPhpDefaultLadder.first.uploadBytes, 50 * (1 << 30));
      expect(nexusPhpDefaultLadder.first.ratio, 1.05);
      expect(nexusPhpDefaultLadder.last.name, 'Nexus Master');
    });

    test('数据齐全：给出下一等级与还差项，保号达标', () {
      final CareEvaluation care = CareRules.evaluate(
        userClass: 'Power User',
        uploadedBytes: 800 * (1 << 30),
        ratio: 5.0,
        joinDate: now.subtract(const Duration(days: 200)),
        now: now,
      );
      expect(care.currentClass, 'Power User');
      // 200 天≈28 周：Power/Elite/Crazy/Insane 均已达成，下一级是 Veteran User（40 周）。
      expect(care.nextClass, 'Veteran User');
      expect(care.careState, CareState.healthy);
      expect(care.careProgress, 1);
      expect(care.steps.length, 8);
      expect(care.steps.first.achieved, isTrue);
      expect(care.steps[1].achieved, isTrue, reason: '200 天≈28 周，Elite User 门槛为 8 周');
      expect(care.steps.last.achieved, isFalse);
      expect(care.steps.last.remaining.contains('还差'), isTrue);
      expect(care.nextClassRequirement.contains('还差'), isTrue);
      expect(care.classPlanLabel.contains('下一等级'), isTrue);
    });

    test('上传不足：写明还差多少上传与天数；分享率不足也点出来', () {
      // 上传 40 GB（低于 Power User 的 50 GB）、注册 20 天（低于 4 周），分享率 1.2 达标。
      final CareEvaluation care = CareRules.evaluate(
        uploadedBytes: 40 * (1 << 30),
        ratio: 1.2,
        joinDate: now.subtract(const Duration(days: 20)),
        now: now,
      );
      expect(care.nextClass, 'Power User');
      expect(care.nextClassRequirement.contains('还差'), isTrue);
      expect(care.nextClassRequirement.contains('上传'), isTrue);
      // 三项里有两项接近达标（平均完成度约 0.84），按口径属于「需关注」而非「有风险」。
      expect(care.careState, CareState.attention);
      expect(care.careProgress, lessThan(1));
      expect(care.policy.minimumRatio, 1.05);
      expect(care.policy.alternatives.length, 2);
      expect(care.policy.note.contains('NexusPHP'), isTrue);

      // 分享率低于门槛时，要求里必须写出目标与当前值。
      final CareEvaluation lowRatio = CareRules.evaluate(
        uploadedBytes: 60 * (1 << 30),
        ratio: 1.01,
        joinDate: now.subtract(const Duration(days: 30)),
        now: now,
      );
      expect(lowRatio.steps.first.achieved, isFalse);
      expect(lowRatio.steps.first.remaining.contains('分享率需 ≥ 1.05'), isTrue);
      expect(lowRatio.careState, isNot(CareState.healthy));

      // 三项都明显不足时标「有掉级风险」。
      final CareEvaluation risky = CareRules.evaluate(
        uploadedBytes: 5 * (1 << 30),
        ratio: 0.5,
        joinDate: now.subtract(const Duration(days: 5)),
        now: now,
      );
      expect(risky.careState, CareState.atRisk);
      expect(risky.careProgress, lessThan(0.8));
    });

    test('数据不足：状态未知，不臆造进度', () {
      final CareEvaluation care = CareRules.evaluate(now: now);
      expect(care.careState, CareState.unknown);
      expect(care.careProgress, 0);
      expect(care.nextClass, 'Power User');
      expect(care.nextClassRequirement.contains('未提供'), isTrue);
    });

    test('分享率 ∞ 视为达标', () {
      final CareEvaluation care = CareRules.evaluate(
        uploadedBytes: 60 * (1 << 30),
        infiniteRatio: true,
        joinDate: now.subtract(const Duration(days: 60)),
        now: now,
      );
      expect(care.steps.first.achieved, isTrue);
      expect(care.policy.satisfiedAlternative.isNotEmpty, isTrue);
    });
  });

  group('本地数据历史', () {
    late StatsHistoryStore store;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    Future<void> initStore() async {
      store = StatsHistoryStore(prefs: PrefsStore(await SharedPreferences.getInstance()));
    }

    test('缺前一自然日基线时，今日增量返回 null（不是 0）', () async {
      await initStore();
      await store.record('s1',
          uploadedBytes: 100, downloadedBytes: 50, bonus: 10, seedingCount: 1,
          now: DateTime(2026, 11, 4, 8));
      expect(store.todayDelta('s1', now: DateTime(2026, 11, 4, 9)), isNull);
    });

    test('两日采样后可算今日增量，累计回退按 0 处理', () async {
      await initStore();
      await store.record('s1',
          uploadedBytes: 100, downloadedBytes: 50, bonus: 10, seedingCount: 1,
          now: DateTime(2026, 11, 3, 20));
      await store.record('s1',
          uploadedBytes: 180, downloadedBytes: 40, bonus: 30, seedingCount: 2,
          now: DateTime(2026, 11, 4, 9));

      final TodayDelta? delta = store.todayDelta('s1', now: DateTime(2026, 11, 4, 10));
      expect(delta, isNotNull);
      expect(delta!.uploadedBytes, 80);
      expect(delta.downloadedBytes, 0, reason: '累计下降时按 0 处理，不显示负数');
    });

    test('综合时魔按两次采样的魔力差值估算，样本不足返回 null', () async {
      await initStore();
      await store.record('s1',
          uploadedBytes: 0, downloadedBytes: 0, bonus: 100, seedingCount: 1,
          now: DateTime(2026, 11, 4, 8));
      expect(store.hourlyBonusEstimate('s1', now: DateTime(2026, 11, 4, 9)), isNull,
          reason: '只有一次采样无法估算');

      await store.record('s1',
          uploadedBytes: 0, downloadedBytes: 0, bonus: 160, seedingCount: 1,
          now: DateTime(2026, 11, 4, 9));
      final double? estimate = store.hourlyBonusEstimate('s1', now: DateTime(2026, 11, 4, 9, 30));
      expect(estimate, closeTo(60, 0.01));
    });

    test('时间轴：非连续日期不标增量，连续日期给出增量', () async {
      await initStore();
      await store.record('s1',
          uploadedBytes: 100, downloadedBytes: 10, bonus: 1, seedingCount: 1,
          now: DateTime(2026, 11, 1, 20));
      await store.record('s1',
          uploadedBytes: 150, downloadedBytes: 20, bonus: 2, seedingCount: 1,
          now: DateTime(2026, 11, 3, 20));
      await store.record('s1',
          uploadedBytes: 200, downloadedBytes: 40, bonus: 3, seedingCount: 1,
          now: DateTime(2026, 11, 4, 20));

      final List<TrendPoint> trend = store.trend('s1', days: 30, now: DateTime(2026, 11, 4, 22));
      expect(trend.length, 3);
      expect(trend.first.date, '2026-11-04', reason: '按日期倒序');
      expect(trend.first.hasBaseline, isTrue);
      expect(trend.first.uploadedDelta, 50);
      expect(trend.first.downloadedDelta, 20);
      final TrendPoint gap = trend.firstWhere((TrendPoint p) => p.date == '2026-11-03');
      expect(gap.hasBaseline, isFalse, reason: '11-02 没有采样，间隔一天以上不当作基线');
    });

    test('清空某站历史后不再返回数据', () async {
      await initStore();
      await store.record('s1',
          uploadedBytes: 1, downloadedBytes: 2, bonus: 3, seedingCount: 4,
          now: DateTime(2026, 11, 4, 8));
      expect(store.samplesOf('s1'), isNotEmpty);
      await store.clearSite('s1');
      expect(store.samplesOf('s1'), isEmpty);
    });

    test('采样数量有上限（不无限膨胀）', () async {
      await initStore();
      for (int i = 0; i < StatsHistoryStore.maxSamplesPerSite + 20; i++) {
        await store.record('s1',
            uploadedBytes: i, downloadedBytes: i, bonus: i, seedingCount: 0,
            now: DateTime(2026, 1, 1).add(Duration(hours: i)));
      }
      expect(
        store.samplesOf('s1').length,
        lessThanOrEqualTo(StatsHistoryStore.maxSamplesPerSite),
      );
      expect(max(1, store.samplesOf('s1').length), greaterThan(1));
    });
  });
}