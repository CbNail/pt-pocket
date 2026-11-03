import 'package:flutter/widgets.dart';

/// 全局设计令牌（Premium 深色设计系统的唯一数值来源）。
///
/// 数值基线来自《PT Pocket 产品需求与设计规格书 v1.1》§6.3 组件规范：
/// 卡片圆角 14–18 dp、页面边距 16 dp、卡片间距 10–12 dp、动效 150–250 ms。
/// 任何页面不得再自行硬编码间距/圆角/时长，统一引用本文件。
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;

  /// 页面统一左右边距 16 dp。
  static const EdgeInsets page = EdgeInsets.symmetric(horizontal: lg);

  /// 卡片之间统一间距。
  static const double cardGap = md;

  /// 卡片内边距。
  static const EdgeInsets cardPadding = EdgeInsets.all(lg);
}

abstract final class AppRadius {
  /// 卡片圆角 14–18 dp，取 16 dp。
  static const double card = 16;
  static const double chip = 10;
  static const double button = 12;
  static const double sheet = 20;
  static const double badge = 8;

  static const BorderRadius cardBorder = BorderRadius.all(Radius.circular(card));
  static const BorderRadius buttonBorder = BorderRadius.all(Radius.circular(button));
}

abstract final class AppDurations {
  /// 动效以 150–250 ms 为主。
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 250);
}

abstract final class AppSizes {
  static const double bottomNavHeight = 64;
  static const double minTouchTarget = 44;
  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;

  /// 状态徽标小面积色块。
  static const double badgeDot = 8;
  static const double badgeBarWidth = 3;
}