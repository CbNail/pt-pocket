import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/providers.dart';

/// 应用启动入口。
///
/// 启动顺序：
/// 1. 初始化 Flutter 绑定；
/// 2. 读取 SharedPreferences（同步可读，作为 Provider 覆盖注入）；
/// 3. 读取应用版本（平台通道不可用时回退内置版本号）；
/// 4. 执行配置继承 / 迁移，补齐默认值并保留用户已填值（需求 16：升级不丢配置）；
/// 5. 加载代理设置与代理密码并套用到 API 客户端（需求 13）；
/// 6. 启动链路守护，监听网络变化使选路缓存失效（需求 16：内外网自动切换）；
/// 7. 挂载 [PtPocketApp]。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final SharedPreferences prefs = await SharedPreferences.getInstance();

  String appVersion = AppConfig.appVersionFallback;
  try {
    final PackageInfo info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) {
      appVersion = info.version;
    }
  } on Exception {
    // 无平台通道（测试 / 桌面预览）时保留内置版本号，不阻塞启动。
  }

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
  );

  await container.read(configInheritanceProvider).initialize(appVersion: appVersion);

  await container.read(proxyRuntimeProvider).load();
  container.read(linkSupervisorProvider).start();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const PtPocketApp(),
    ),
  );
}