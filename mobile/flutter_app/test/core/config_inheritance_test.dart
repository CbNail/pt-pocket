// 配置继承 / 迁移测试（需求 #17）：升级迭代后 App 端已填配置自动继承、不被覆盖。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/config/app_config.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/storage/config_inheritance.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late PrefsStore prefs;
  late ConfigInheritanceService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = PrefsStore(await SharedPreferences.getInstance());
    // SecureStore 仅构造，不触发平台通道调用。
    service = ConfigInheritanceService(prefs: prefs, secure: SecureStore());
  });

  test('全新安装：补齐默认值并写入 schema 版本与 App 版本', () async {
    final ConfigInheritanceResult result = await service.initialize(appVersion: '0.7.0');

    expect(result.isFreshInstall, isTrue);
    expect(result.didMigrate, isTrue);
    expect(result.toVersion, AppConfig.configSchemaVersion);
    expect(result.appliedMigrations.length, AppConfig.configSchemaVersion);

    expect(prefs.getString('link.mode'), 'auto');
    expect(prefs.getString('theme.mode'), 'dark');
    expect(prefs.getInt('search.pageSize'), 50);
    expect(prefs.getInt('config.schemaVersion'), AppConfig.configSchemaVersion);
    expect(prefs.getString('config.lastAppVersion'), '0.7.0');
  });

  test('旧版本升级：迁移链执行且用户已填配置被保留', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ptp.server.baseUrl': 'http://192.168.1.10:8000',
      'ptp.theme.mode': 'light',
      'ptp.config.schemaVersion': 1,
    });
    final PrefsStore old = PrefsStore(await SharedPreferences.getInstance());
    final ConfigInheritanceService legacy = ConfigInheritanceService(
      prefs: old,
      secure: SecureStore(),
    );

    final ConfigInheritanceResult result = await legacy.initialize(appVersion: '0.7.0');

    expect(result.fromVersion, 1);
    expect(
      result.appliedMigrations,
      <String>['1_to_2_dual_endpoint', '2_to_3_proxy_and_search', '3_to_4_moviepilot_dual_endpoint'],
    );

    // 旧单一地址迁移到内网通道，并删除旧键。
    expect(old.getString('endpoint.lan'), 'http://192.168.1.10:8000');
    expect(old.getString('server.baseUrl'), isNull);
    // 用户已填的外观设置保持原值。
    expect(old.getString('theme.mode'), 'light');
    expect(old.getInt('config.schemaVersion'), AppConfig.configSchemaVersion);
  });

  test('重复启动幂等：不再追加迁移，也不覆盖用户值', () async {
    await service.initialize(appVersion: '0.7.0');
    await prefs.setString('theme.mode', 'light');

    final ConfigInheritanceResult second = await service.initialize(appVersion: '0.7.1');

    expect(second.appliedMigrations, isEmpty);
    expect(second.fromVersion, AppConfig.configSchemaVersion);
    expect(prefs.getString('theme.mode'), 'light');
    expect(prefs.getString('config.lastAppVersion'), '0.7.1');
  });

  test('v3 -> v4：MoviePilot 旧单一地址按内网/公网归入对应通道且不丢字段', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ptp.config.schemaVersion': 3,
      'ptp.moviepilot.index': jsonEncode(<String, dynamic>{
        'version': 1,
        'instances': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'mp-lan',
            'name': '本机 MP',
            'baseUrl': 'http://192.168.1.10:3000',
            'version': 'v2',
          },
          <String, dynamic>{
            'id': 'mp-wan',
            'name': '远程 MP',
            'baseUrl': 'https://mp.example.com',
            'version': 'v2',
          },
        ],
      }),
    });
    final PrefsStore legacyPrefs = PrefsStore(await SharedPreferences.getInstance());
    final ConfigInheritanceService legacy = ConfigInheritanceService(
      prefs: legacyPrefs,
      secure: SecureStore(),
    );

    final ConfigInheritanceResult result = await legacy.initialize(appVersion: '0.7.1');
    expect(result.appliedMigrations, contains('3_to_4_moviepilot_dual_endpoint'));

    final Map<String, dynamic>? index = legacyPrefs.getJson('moviepilot.index');
    final List<dynamic> instances = index!['instances'] as List<dynamic>;
    final Map<String, dynamic> lan = Map<String, dynamic>.from(instances[0] as Map);
    final Map<String, dynamic> wan = Map<String, dynamic>.from(instances[1] as Map);

    expect(lan['lanBaseUrl'], 'http://192.168.1.10:3000');
    expect(lan['wanBaseUrl'], '');
    expect(wan['wanBaseUrl'], 'https://mp.example.com');
    expect(wan['lanBaseUrl'], '');
    // 原有字段保留
    expect(lan['name'], '本机 MP');
    // 模型读出来仍然可用，且旧地址没有丢
    final MpInstance model = MpInstance.fromJson(lan);
    expect(model.lanUri.toString(), 'http://192.168.1.10:3000');
    expect(model.hasAnyAddress, isTrue);
  });
}