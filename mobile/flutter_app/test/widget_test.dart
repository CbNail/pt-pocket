// 骨架阶段的冒烟测试：主题基线、状态徽标渲染与应用外壳的五个主入口。
//
// 后续模块的页面级测试放在 test/features/ 下，与 lib/features/ 目录对应。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/app.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/theme/app_colors.dart';
import 'package:pt_pocket/core/theme/app_theme.dart';
import 'package:pt_pocket/shared/widgets/status_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('深色主题以品牌色为主色', () {
    final ThemeData theme = AppTheme.dark();
    expect(theme.brightness, Brightness.dark);
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.primary, AppColors.brand);
  });

  test('浅色主题以浅色品牌色为主色', () {
    expect(AppTheme.light().colorScheme.primary, AppColors.lightBrand);
  });

  testWidgets('状态徽标同时渲染文字与图标（颜色不是唯一的状态表达）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: Center(
            child: StatusBadge(
              label: '正常',
              tone: StatusTone.ok,
              icon: Icons.check_circle_outline,
            ),
          ),
        ),
      ),
    );

    expect(find.text('正常'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('应用外壳渲染五个底部主入口', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const PtPocketApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 底部导航的五个主入口标签都应存在；
    // 首页内容里可能也出现同名文本（如「下载器」统计项），因此用 findsWidgets。
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final String label in <String>['首页', '搜索', '站点', '下载器', '我的']) {
      expect(find.text(label), findsWidgets, reason: '底部入口「$label」应存在');
    }
    expect(find.text('PT Pocket'), findsOneWidget);
  });
}