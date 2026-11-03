// 地址档案持久化测试（需求 16 / 17）：
// 保存后即刻落盘，重建 Provider 容器（等价于 App 重启 / 版本升级）后配置仍然保留。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/network/endpoint_resolver.dart';
import 'package:pt_pocket/core/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('内外网地址与链路模式落盘，重建容器后仍保留', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final ProviderContainer first = ProviderContainer(
      overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(first.dispose);

    await first.read(endpointProfileProvider.notifier).update(
          lan: Uri.parse('http://192.168.1.10:8000'),
          wan: Uri.parse('https://pt.example.com'),
          mode: LinkMode.auto,
        );

    final ProviderContainer second = ProviderContainer(
      overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(second.dispose);

    final EndpointProfile profile = second.read(endpointProfileProvider);
    expect(profile.lanBaseUrl.toString(), 'http://192.168.1.10:8000');
    expect(profile.wanBaseUrl.toString(), 'https://pt.example.com');
    expect(profile.mode, LinkMode.auto);
    expect(profile.isConfigured, isTrue);
  });

  test('切换为仅外网模式会被持久化', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final ProviderContainer first = ProviderContainer(
      overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(first.dispose);
    await first.read(endpointProfileProvider.notifier).update(mode: LinkMode.wan);

    final ProviderContainer second = ProviderContainer(
      overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(second.dispose);

    expect(second.read(endpointProfileProvider).mode, LinkMode.wan);
  });

  test('清空内网地址后不再是已配置状态', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await container.read(endpointProfileProvider.notifier).update(
          lan: Uri.parse('http://192.168.1.10:8000'),
        );
    expect(container.read(endpointProfileProvider).isConfigured, isTrue);

    await container.read(endpointProfileProvider.notifier).update(clearLan: true);
    expect(container.read(endpointProfileProvider).isConfigured, isFalse);
    expect(container.read(endpointProfileProvider).lanBaseUrl, isNull);
  });
}