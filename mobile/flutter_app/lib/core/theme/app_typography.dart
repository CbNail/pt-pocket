import 'package:flutter/material.dart';

/// 字体层级：信息密度高但不拥挤。
///
/// 通过字重、字号和行高建立层级，而非大面积色块。系统字体放大时应不裁切。
abstract final class AppTypography {
  static const String? fontFamily = null; // 使用系统字体（鸿蒙/Android 各自平台默认）

  static TextTheme textTheme(Color primary, Color secondary, Color muted) {
    return TextTheme(
      displaySmall: TextStyle(fontSize: 30, height: 1.2, fontWeight: FontWeight.w600, color: primary),
      headlineMedium: TextStyle(fontSize: 24, height: 1.25, fontWeight: FontWeight.w600, color: primary),
      headlineSmall: TextStyle(fontSize: 20, height: 1.3, fontWeight: FontWeight.w600, color: primary),
      titleLarge: TextStyle(fontSize: 18, height: 1.3, fontWeight: FontWeight.w600, color: primary),
      titleMedium: TextStyle(fontSize: 16, height: 1.35, fontWeight: FontWeight.w600, color: primary),
      titleSmall: TextStyle(fontSize: 14, height: 1.35, fontWeight: FontWeight.w600, color: primary),
      bodyLarge: TextStyle(fontSize: 15, height: 1.45, fontWeight: FontWeight.w400, color: primary),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w400, color: secondary),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w400, color: secondary),
      labelLarge: TextStyle(fontSize: 14, height: 1.3, fontWeight: FontWeight.w600, color: primary),
      labelMedium: TextStyle(fontSize: 12, height: 1.3, fontWeight: FontWeight.w500, color: secondary),
      labelSmall: TextStyle(fontSize: 11, height: 1.3, fontWeight: FontWeight.w500, color: muted),
    );
  }
}