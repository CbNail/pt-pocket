import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// 迷你速率曲线：只在拿到 ≥2 个采样点时画线，否则显示「采样中」。
///
/// 采样来自 [DownloaderSpeedHistory]（内存环），因此这里画的是真实观测值，
/// 不会为了「看起来有图」而补造数据点。
class MiniSparkline extends StatelessWidget {
  const MiniSparkline({
    super.key,
    required this.values,
    required this.color,
    this.height = 40,
  });

  /// 按时间先后排列的速率序列（字节/秒）。
  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '速率曲线采样中：刷新几次后按实际观测值绘制',
            style: theme.textTheme.labelSmall,
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: values,
          color: color,
          baseline: theme.colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.color, required this.baseline});

  final List<double> values;
  final Color color;
  final Color baseline;

  @override
  void paint(Canvas canvas, Size size) {
    final double maxValue = values.reduce(math.max);
    final double scale = maxValue <= 0 ? 1 : maxValue;
    final double stepX = size.width / (values.length - 1);

    // 基线：即使全为 0 也让坐标系可见。
    final Paint axis = Paint()
      ..color = baseline
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 1), Offset(size.width, size.height - 1), axis);

    final Path line = Path();
    for (int i = 0; i < values.length; i++) {
      final double x = stepX * i;
      final double y = size.height - (values[i] / scale) * (size.height - 2) - 1;
      if (i == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }

    final Path fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[color.withValues(alpha: 0.35), color.withValues(alpha: 0.02)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

/// 迷你分类柱状图：等宽柱、每根柱下方一行标签，行内不留半格。
class MiniBarChart extends StatelessWidget {
  const MiniBarChart({
    super.key,
    required this.entries,
    required this.color,
    this.barHeight = 34,
    this.maxBars = 5,
    this.emptyHint = '暂无分类',
  });

  /// 分类 → 任务数（调用方按数量倒序传入）。
  final List<MapEntry<String, int>> entries;
  final Color color;
  final double barHeight;
  final int maxBars;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<MapEntry<String, int>> visible =
        entries.take(maxBars).toList(growable: false);
    if (visible.isEmpty) {
      return SizedBox(
        height: barHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(emptyHint, style: theme.textTheme.labelSmall),
        ),
      );
    }
    final int maxValue = visible
        .map((MapEntry<String, int> e) => e.value)
        .reduce((int a, int b) => math.max(a, b));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          height: barHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (final MapEntry<String, int> entry in visible)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        // 最矮也留 3dp，0 值不至于完全看不见。
                        height: math.max(3, barHeight * (entry.value / (maxValue <= 0 ? 1 : maxValue))),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.85),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(AppRadius.chip / 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxs),
        Row(
          children: <Widget>[
            for (final MapEntry<String, int> entry in visible)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    entry.key,
                    style: theme.textTheme.labelSmall,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 状态占比环：只由真实计数绘制；总数为 0 时画一圈中性底环。
class MiniDonut extends StatelessWidget {
  const MiniDonut({
    super.key,
    required this.slices,
    this.size = 56,
    this.thickness = 8,
    this.centerLabel,
    this.centerCaption,
  });

  final List<({String label, int value, Color color})> slices;
  final double size;
  final double thickness;

  /// 环心数值与说明（例如「473 / 做种」）。
  final String? centerLabel;
  final String? centerCaption;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int total = slices.fold(0, (int sum, ({String label, int value, Color color}) s) => sum + s.value);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          CustomPaint(
            size: Size(size, size),
            painter: _DonutPainter(
              slices: slices,
              total: total,
              thickness: thickness,
              emptyColor: theme.colorScheme.surfaceContainerHigh,
            ),
          ),
          if (centerLabel != null)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  centerLabel!,
                  style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (centerCaption != null)
                  Text(centerCaption!, style: theme.textTheme.labelSmall),
              ],
            ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.slices,
    required this.total,
    required this.thickness,
    required this.emptyColor,
  });

  final List<({String label, int value, Color color})> slices;
  final int total;
  final double thickness;
  final Color emptyColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final double radius = (math.min(size.width, size.height) - thickness) / 2;
    final Paint base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..color = emptyColor;
    canvas.drawCircle(rect.center, radius, base);

    if (total <= 0) return;

    double startAngle = -math.pi / 2;
    for (final ({String label, int value, Color color}) slice in slices) {
      if (slice.value <= 0) continue;
      final double sweep = 2 * math.pi * (slice.value / total);
      final Paint paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.butt
        ..color = slice.color;
      canvas.drawArc(Rect.fromCircle(center: rect.center, radius: radius), startAngle, sweep, false, paint);
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.total != total || oldDelegate.slices != slices;
}