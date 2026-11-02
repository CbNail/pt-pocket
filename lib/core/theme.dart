import 'package:flutter/material.dart';

/// PT Pocket 全局主题：深色 PT 风（墨黑底 + 翡翠绿点缀）
class AppTheme {
  static const seed = Color(0xFF3DDC84);

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0E1116),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0E1116),
        elevation: 0,
        centerTitle: false,
      ),
    );
  }
}
