import '../models/status_models.dart';
import '../utils/format.dart';

/// 站点等级门槛（养老进度用）。
class LevelRequirement {
  const LevelRequirement({
    required this.name,
    required this.weeks,
    required this.uploadBytes,
    required this.ratio,
  });

  final String name;

  /// 注册满多少周。
  final int weeks;
  final int uploadBytes;
  final double ratio;

  String get requirementText =>
      '注册满 $weeks 周 · 上传 ${formatBytes(uploadBytes)} · 分享率 ≥ ${ratio.toStringAsFixed(2)}';
}

/// NexusPHP 默认等级路线。
///
/// 这是 NexusPHP 默认的升等方式（注册时长 + 上传量 + 分享率），被绝大多数
/// NexusPHP 站点沿用；站点自定义升等规则（例如再加做种数 / 魔力值门槛）不在其中，
/// 因此页面上把本口径标注为「默认口径估算」，不当作站点官方规则。
const List<LevelRequirement> nexusPhpDefaultLadder = <LevelRequirement>[
  LevelRequirement(name: 'Power User', weeks: 4, uploadBytes: 50 * (1 << 30), ratio: 1.05),
  LevelRequirement(name: 'Elite User', weeks: 8, uploadBytes: 120 * (1 << 30), ratio: 1.55),
  LevelRequirement(name: 'Crazy User', weeks: 15, uploadBytes: 300 * (1 << 30), ratio: 2.05),
  LevelRequirement(name: 'Insane User', weeks: 25, uploadBytes: 500 * (1 << 30), ratio: 2.55),
  LevelRequirement(name: 'Veteran User', weeks: 40, uploadBytes: 750 * (1 << 30), ratio: 3.05),
  LevelRequirement(name: 'Extreme User', weeks: 60, uploadBytes: 1 << 40, ratio: 3.55),
  LevelRequirement(name: 'Ultimate User', weeks: 80, uploadBytes: 3 * (1 << 39), ratio: 4.05),
  LevelRequirement(name: 'Nexus Master', weeks: 100, uploadBytes: 3 * (1 << 40), ratio: 4.55),
];

/// 默认保号目标等级（达到该等级即视为「保号安全」）。
const String defaultSafeLevel = 'Power User';

/// 一次养老进度评估结果。
class CareEvaluation {
  const CareEvaluation({
    required this.currentClass,
    required this.nextClass,
    required this.nextClassRequirement,
    required this.steps,
    required this.careState,
    required this.careProgress,
    required this.policy,
    this.note = '',
  });

  final String currentClass;
  final String nextClass;
  final String nextClassRequirement;
  final List<LevelStep> steps;
  final CareState careState;
  final double careProgress;
  final SiteCarePolicy policy;
  final String note;

  /// 等级路线一句话摘要（页面直接展示）。
  String get classPlanLabel {
    if (nextClass.isEmpty) {
      return currentClass.isEmpty ? '' : '已是最高等级：$currentClass';
    }
    if (nextClassRequirement.isEmpty) return '下一等级：$nextClass';
    return '下一等级：$nextClass（$nextClassRequirement）';
  }
}

/// 养老进度评估：按等级路线 + 保号目标给出进度与状态。
abstract final class CareRules {
  /// 评估；
  /// [userClass] 为站点页面给出的当前等级（可能为空），
  /// [uploadedBytes] / [ratio] / [joinDate] 缺失时按「数据未提供」处理，
  /// 不拿 0 冒充（缺失会把状态标成 [CareState.unknown]）。
  static CareEvaluation evaluate({
    String userClass = '',
    int? uploadedBytes,
    double? ratio,
    bool infiniteRatio = false,
    DateTime? joinDate,
    DateTime? now,
    List<LevelRequirement> ladder = nexusPhpDefaultLadder,
    String safeLevel = defaultSafeLevel,
  }) {
    final DateTime current = now ?? DateTime.now();
    final List<LevelStep> steps = <LevelStep>[];
    final bool hasCore = uploadedBytes != null && (ratio != null || infiniteRatio);

    int? currentIndex;
    int? nextIndex;
    for (int i = 0; i < ladder.length; i++) {
      final LevelRequirement level = ladder[i];
      final bool achieved = hasCore &&
          _weeksSince(joinDate, current) >= level.weeks &&
          uploadedBytes >= level.uploadBytes &&
          (infiniteRatio || (ratio ?? 0) >= level.ratio);
      steps.add(
        LevelStep(
          name: level.name,
          requirement: level.requirementText,
          achieved: achieved,
          remaining: achieved
              ? ''
              : _remainingText(
                  level: level,
                  joinDate: joinDate,
                  uploadedBytes: uploadedBytes,
                  ratio: ratio,
                  infiniteRatio: infiniteRatio,
                  now: current,
                ),
        ),
      );
      if (achieved) currentIndex = i;
      if (!achieved && nextIndex == null) nextIndex = i;
    }

    final int safeIndex = ladder.indexWhere((LevelRequirement l) => l.name == safeLevel);
    final LevelRequirement safe = safeIndex >= 0 ? ladder[safeIndex] : ladder.first;

    final String resolvedClass = userClass.isNotEmpty
        ? userClass
        : (currentIndex == null ? '' : ladder[currentIndex].name);

    final LevelRequirement? next = nextIndex == null ? null : ladder[nextIndex];
    final String nextRequirement = next == null
        ? ''
        : _remainingText(
            level: next,
            joinDate: joinDate,
            uploadedBytes: uploadedBytes,
            ratio: ratio,
            infiniteRatio: infiniteRatio,
            now: current,
          );

    // 保号：以「默认保号等级」的门槛衡量进度；缺数据时不猜。
    final CareState state;
    final double progress;
    if (!hasCore) {
      state = CareState.unknown;
      progress = 0;
    } else {
      progress = _safeProgress(
        safe: safe,
        joinDate: joinDate,
        uploadedBytes: uploadedBytes,
        ratio: infiniteRatio ? safe.ratio : (ratio ?? 0),
        now: current,
      );
      if (progress >= 1) {
        state = CareState.healthy;
      } else if (progress >= 0.8) {
        state = CareState.attention;
      } else {
        state = CareState.atRisk;
      }
    }

    final String metAlternative = _metAlternative(
      safe: safe,
      joinDate: joinDate,
      uploadedBytes: uploadedBytes,
      ratio: ratio,
      infiniteRatio: infiniteRatio,
      now: current,
    );

    return CareEvaluation(
      currentClass: resolvedClass,
      nextClass: next?.name ?? '',
      nextClassRequirement: nextRequirement,
      steps: steps,
      careState: state,
      careProgress: progress.clamp(0, 1),
      policy: SiteCarePolicy(
        minimumRatio: safe.ratio,
        minimumUploadBytes: safe.uploadBytes,
        requiresSignIn: true,
        alternatives: <String>[
          '分享率 ≥ ${safe.ratio.toStringAsFixed(2)} 且上传量 ≥ ${formatBytes(safe.uploadBytes)}',
          '注册满 ${safe.weeks} 周并保持账号活跃（定期登录、保持做种）',
        ],
        satisfiedAlternative: metAlternative,
        note: '保号口径按 ${safe.name} 门槛（NexusPHP 默认规则）估算；'
            '站点自定义升等 / 保号规则可能与之不同。',
      ),
      note: '等级门槛按 NexusPHP 默认口径估算（注册时长 + 上传量 + 分享率），'
          '站点自定义规则可能不同。',
    );
  }

  static int _weeksSince(DateTime? joinDate, DateTime now) {
    if (joinDate == null) return 0;
    return now.difference(joinDate).inDays ~/ 7;
  }

  static double _safeProgress({
    required LevelRequirement safe,
    required DateTime? joinDate,
    required int uploadedBytes,
    required double ratio,
    required DateTime now,
  }) {
    final List<double> parts = <double>[];
    if (joinDate != null) {
      final int days = now.difference(joinDate).inDays;
      parts.add((days / (safe.weeks * 7)).clamp(0, 1));
    }
    parts.add((uploadedBytes / safe.uploadBytes).clamp(0, 1));
    parts.add((ratio / safe.ratio).clamp(0, 1));
    final double sum = parts.fold(0, (double a, double b) => a + b);
    return sum / parts.length;
  }

  static String _metAlternative({
    required LevelRequirement safe,
    required DateTime? joinDate,
    required int? uploadedBytes,
    required double? ratio,
    required bool infiniteRatio,
    required DateTime now,
  }) {
    if (uploadedBytes == null || (ratio == null && !infiniteRatio)) return '';
    final bool ratioOk = infiniteRatio || (ratio ?? 0) >= safe.ratio;
    final bool uploadOk = uploadedBytes >= safe.uploadBytes;
    if (ratioOk && uploadOk) {
      return '分享率 ≥ ${safe.ratio.toStringAsFixed(2)} 且上传量 ≥ ${formatBytes(safe.uploadBytes)}';
    }
    if (joinDate != null && _weeksSince(joinDate, now) >= safe.weeks) {
      return '注册满 ${safe.weeks} 周并保持账号活跃（定期登录、保持做种）';
    }
    return '';
  }

  static String _remainingText({
    required LevelRequirement level,
    required DateTime? joinDate,
    required int? uploadedBytes,
    required double? ratio,
    required bool infiniteRatio,
    required DateTime now,
  }) {
    final List<String> parts = <String>[];
    if (joinDate != null) {
      final int days = now.difference(joinDate).inDays;
      final int required = level.weeks * 7;
      if (days < required) {
        final DateTime reach = joinDate.add(Duration(days: required));
        parts.add('还差 ${required - days} 天（${_formatDate(reach)}）');
      }
    } else {
      parts.add('注册时间未提供，无法判断时长');
    }
    if (uploadedBytes == null) {
      parts.add('上传量未提供');
    } else if (uploadedBytes < level.uploadBytes) {
      parts.add('还差 ${formatBytes(level.uploadBytes - uploadedBytes)} 上传');
    }
    if (!infiniteRatio) {
      if (ratio == null) {
        parts.add('分享率未提供');
      } else if (ratio < level.ratio) {
        parts.add('分享率需 ≥ ${level.ratio.toStringAsFixed(2)}（当前 ${ratio.toStringAsFixed(2)}）');
      }
    }
    return parts.join('、');
  }

  static String _formatDate(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }
}