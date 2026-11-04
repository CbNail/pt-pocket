// PTD 备份「选文件」入口的界面级测试：走 app 自带的平台通道（Android），
// 选到 zip 后自动解析、列出成员处理情况；用户取消时不报错。

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:pt_pocket/core/services/platform_file_picker.dart';
import 'package:pt_pocket/features/sites/ptd_import_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 造一个与 PTD 导出结构相近的 zip 备份。
Uint8List _zipBytes() {
  final Archive archive = Archive()
    ..addFile(ArchiveFile.string(
      'manifest.json',
      jsonEncode(<String, dynamic>{'app': 'PT-depiler', 'version': '0.2.3'}),
    ))
    ..addFile(ArchiveFile.string(
      'config.json',
      jsonEncode(<String, dynamic>{
        'sites': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'M-Team', 'baseUrl': 'https://m-team.example'},
        ],
      }),
    ))
    ..addFile(ArchiveFile.string(
      'cookies.json',
      jsonEncode(<String, dynamic>{'m-team.example': 'sid=abc'}),
    ));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    prefs = await SharedPreferences.getInstance();
  });

  /// 指定平台跑一段测试体；`debugDefaultTargetPlatformOverride` 必须在测试体内复原，
  /// 否则框架的 foundation 变量检查会直接判定失败。
  Future<void> onPlatform(TargetPlatform platform, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> pumpPage(WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PtdImportPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  ProviderContainer newContainer() => ProviderContainer(
        overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
      );

  testWidgets('选中 zip 备份后自动解析出站点并列出成员处理情况', (WidgetTester tester) async {
    await onPlatform(TargetPlatform.android, () async {
      final Uint8List bytes = _zipBytes();
      final List<MethodCall> calls = <MethodCall>[];

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformFilePicker.defaultChannel,
        (MethodCall call) async {
          calls.add(call);
          if (call.method == 'pickFile') {
            return <Object?, Object?>{'name': 'PTD_backup.zip', 'bytes': bytes};
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformFilePicker.defaultChannel, null));

      final ProviderContainer container = newContainer();
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();

      expect(calls.single.method, 'pickFile');
      expect(find.text('PTD_backup.zip'), findsOneWidget);
      expect(find.text('M-Team'), findsOneWidget);
      expect(find.textContaining('已采用'), findsWidgets);
      expect(find.textContaining('已忽略'), findsWidgets);
    });
  });

  testWidgets('用户取消选择时不报错、不产生结果', (WidgetTester tester) async {
    await onPlatform(TargetPlatform.android, () async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformFilePicker.defaultChannel,
        (MethodCall call) async => null,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformFilePicker.defaultChannel, null));

      final ProviderContainer container = newContainer();
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();

      expect(find.text('解析结果'), findsNothing);
      expect(find.textContaining('选择文件失败'), findsNothing);
    });
  });

  testWidgets('非 Android 平台给出可执行的替代提示', (WidgetTester tester) async {
    await onPlatform(TargetPlatform.windows, () async {
      final ProviderContainer container = newContainer();
      addTearDown(container.dispose);
      await pumpPage(tester, container);

      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();

      expect(find.textContaining('请改用下面的「粘贴备份 JSON」'), findsOneWidget);
    });
  });
}