import 'package:flutter/material.dart';

/// 品牌与语义色板。
///
/// 来源：《PT Pocket 产品需求与设计规格书 v1.1》§6.2 色彩建议。
/// 色值为设计基线；颜色不能成为唯一状态表达方式，需同时使用文字、图标或形状。
abstract final class AppColors {
  // ---------- 深色（默认主题） ----------
  static const Color bgBase = Color(0xFF0B0F14); // 全局页面底色
  static const Color bgSurface = Color(0xFF111821); // 页面分区 / 底部栏
  static const Color bgCard = Color(0xFF17212B); // 主卡片、列表容器
  static const Color border = Color(0xFF263342); // 低对比边界
  static const Color brand = Color(0xFF35D39A); // 主操作、正常状态、选中态
  static const Color info = Color(0xFF6CA9FF); // 链路、说明和中性信息
  static const Color warning = Color(0xFFFFB454); // 需要关注但未到严重程度
  static const Color danger = Color(0xFFFF647C); // 故障、病危和破坏性操作
  static const Color textPrimary = Color(0xFFF2F5F8); // 标题和主要内容
  static const Color textSecondary = Color(0xFFA8B4C0); // 辅助信息
  static const Color textMuted = Color(0xFF687787); // 时间戳、禁用说明

  // ---------- 浅色（跟随系统模式时使用） ----------
  static const Color lightBgBase = Color(0xFFF4F6F9);
  static const Color lightBgSurface = Color(0xFFFFFFFF);
  static const Color lightBgCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFD9E0E8);
  static const Color lightBrand = Color(0xFF12996E);
  static const Color lightInfo = Color(0xFF2F6FE0);
  static const Color lightWarning = Color(0xFFB36A00);
  static const Color lightDanger = Color(0xFFD2324C);
  static const Color lightTextPrimary = Color(0xFF12181F);
  static const Color lightTextSecondary = Color(0xFF4A5764);
  static const Color lightTextMuted = Color(0xFF7A8794);

  /// 深色语义色方案（App 默认）。
  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: brand,
    onPrimary: Color(0xFF04231A),
    secondary: info,
    onSecondary: Color(0xFF04203F),
    tertiary: warning,
    onTertiary: Color(0xFF2A1A00),
    error: danger,
    onError: Color(0xFF2A0810),
    surface: bgBase,
    onSurface: textPrimary,
    surfaceContainerLowest: bgBase,
    surfaceContainerLow: bgSurface,
    surfaceContainer: bgCard,
    surfaceContainerHigh: Color(0xFF1C2833),
    surfaceContainerHighest: Color(0xFF22303D),
    onSurfaceVariant: textSecondary,
    outline: border,
    outlineVariant: Color(0xFF1E2A37),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: textPrimary,
    onInverseSurface: bgBase,
    inversePrimary: lightBrand,
  );

  /// 浅色语义色方案。
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: lightBrand,
    onPrimary: Color(0xFFFFFFFF),
    secondary: lightInfo,
    onSecondary: Color(0xFFFFFFFF),
    tertiary: lightWarning,
    onTertiary: Color(0xFFFFFFFF),
    error: lightDanger,
    onError: Color(0xFFFFFFFF),
    surface: lightBgBase,
    onSurface: lightTextPrimary,
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: lightBgSurface,
    surfaceContainer: lightBgCard,
    surfaceContainerHigh: Color(0xFFEDF1F6),
    surfaceContainerHighest: Color(0xFFE3E9F0),
    onSurfaceVariant: lightTextSecondary,
    outline: lightBorder,
    outlineVariant: Color(0xFFE6EBF1),
    shadow: Color(0x14000000),
    scrim: Color(0x80000000),
    inverseSurface: lightTextPrimary,
    onInverseSurface: Color(0xFFFFFFFF),
    inversePrimary: brand,
  );
}

/// 语义状态色：站点健康 / 任务状态 / 链路类型统一取值入口。
enum StatusTone { ok, info, warning, danger, neutral }

extension StatusToneColor on StatusTone {
  Color resolve(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    switch (this) {
      case StatusTone.ok:
        return dark ? AppColors.brand : AppColors.lightBrand;
      case StatusTone.info:
        return dark ? AppColors.info : AppColors.lightInfo;
      case StatusTone.warning:
        return dark ? AppColors.warning : AppColors.lightWarning;
      case StatusTone.danger:
        return dark ? AppColors.danger : AppColors.lightDanger;
      case StatusTone.neutral:
        return dark ? AppColors.textMuted : AppColors.lightTextMuted;
    }
  }
}