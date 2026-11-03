import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config/app_config.dart';
import 'models/proxy_settings.dart';
import 'network/api_client.dart';
import 'network/endpoint_resolver.dart';
import 'network/interceptors.dart';
import 'network/link_supervisor.dart';
import 'network/proxy_runtime.dart';
import 'storage/app_keys.dart';
import 'storage/config_inheritance.dart';
import 'storage/prefs_store.dart';
import 'storage/secure_store.dart';

/// SharedPreferences 实例由 main() 在启动时注入（overrides），保证同步可读。
final Provider<SharedPreferences> sharedPreferencesProvider = Provider<SharedPreferences>(
  (Ref ref) => throw UnimplementedError('sharedPreferencesProvider 必须在 ProviderScope 中 override'),
);

final Provider<PrefsStore> prefsStoreProvider = Provider<PrefsStore>(
  (Ref ref) => PrefsStore(ref.watch(sharedPreferencesProvider)),
);

final Provider<SecureStore> secureStoreProvider = Provider<SecureStore>(
  (Ref ref) => SecureStore(),
);

/// 配置继承 / 迁移服务（需求 #17）。
final Provider<ConfigInheritanceService> configInheritanceProvider =
    Provider<ConfigInheritanceService>(
  (Ref ref) => ConfigInheritanceService(
    prefs: ref.watch(prefsStoreProvider),
    secure: ref.watch(secureStoreProvider),
  ),
);

/// NAS 会话令牌（异步读取安全存储）。
final FutureProvider<String?> nasSessionTokenProvider = FutureProvider<String?>(
  (Ref ref) => ref.watch(secureStoreProvider).read(SecureKeys.nasSessionToken),
);

/// 链路与地址档案（可持久化、可手动覆盖，用于排障）。
final NotifierProvider<EndpointProfileNotifier, EndpointProfile> endpointProfileProvider =
    NotifierProvider<EndpointProfileNotifier, EndpointProfile>(EndpointProfileNotifier.new);

class EndpointProfileNotifier extends Notifier<EndpointProfile> {
  @override
  EndpointProfile build() {
    final PrefsStore prefs = ref.watch(prefsStoreProvider);
    return EndpointProfile(
      lanBaseUrl: parseBaseUrl(prefs.getString(PrefKeys.endpointLan)),
      wanBaseUrl: parseBaseUrl(prefs.getString(PrefKeys.endpointWan)),
      mode: LinkMode.fromName(prefs.getString(PrefKeys.linkMode)),
    );
  }

  /// 宽松解析：允许用户只填 `192.168.1.10:8000`，自动补 http 协议。
  static Uri? parseBaseUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final String value = raw.trim();
    return Uri.tryParse(value.contains('://') ? value : 'http://$value');
  }

  Future<void> update({
    Uri? lan,
    Uri? wan,
    LinkMode? mode,
    bool clearLan = false,
    bool clearWan = false,
  }) async {
    final PrefsStore prefs = ref.read(prefsStoreProvider);
    if (clearLan) {
      await prefs.setString(PrefKeys.endpointLan, '');
    } else if (lan != null) {
      await prefs.setString(PrefKeys.endpointLan, lan.toString());
    }
    if (clearWan) {
      await prefs.setString(PrefKeys.endpointWan, '');
    } else if (wan != null) {
      await prefs.setString(PrefKeys.endpointWan, wan.toString());
    }
    if (mode != null) {
      await prefs.setString(PrefKeys.linkMode, mode.name);
    }
    state = EndpointProfile(
      lanBaseUrl: clearLan ? null : (lan ?? state.lanBaseUrl),
      wanBaseUrl: clearWan ? null : (wan ?? state.wanBaseUrl),
      mode: mode ?? state.mode,
    );
  }
}

/// 健康探测实现（独立最小 Dio，避免循环依赖；不套用代理，保证探测结果真实）。
final Provider<HttpHealthProbe> healthProbeProvider = Provider<HttpHealthProbe>(
  (Ref ref) => HttpHealthProbe(),
);

/// 双链路解析器：随地址档案或链路模式变化自动重建。
final Provider<EndpointResolver> endpointResolverProvider = Provider<EndpointResolver>((Ref ref) {
  final EndpointProfile profile = ref.watch(endpointProfileProvider);
  return EndpointResolver(probe: ref.watch(healthProbeProvider).call, profile: profile);
});

/// 统一 API 客户端。
final Provider<ApiClient> apiClientProvider = Provider<ApiClient>((Ref ref) {
  final ApiClient client = ApiClient(resolver: ref.watch(endpointResolverProvider));
  client.addInterceptor(IdempotencyInterceptor());
  client.addInterceptor(
    AuthInterceptor(
      tokenReader: () => ref.read(secureStoreProvider).read(SecureKeys.nasSessionToken),
      onUnauthorized: () async => ref.read(secureStoreProvider).delete(SecureKeys.nasSessionToken),
    ),
  );
  client.addInterceptor(RedactingLogInterceptor());
  return client;
});

/// 系统网络变化流：用于触发选路缓存失效与链路重选（需求 #16）。
final StreamProvider<List<ConnectivityResult>> connectivityProvider =
    StreamProvider<List<ConnectivityResult>>(
  (Ref ref) => Connectivity().onConnectivityChanged,
);

/// 链路守护：把网络变化接到选路缓存失效上（需求 #16）。
final Provider<LinkSupervisor> linkSupervisorProvider = Provider<LinkSupervisor>((Ref ref) {
  final LinkSupervisor supervisor = LinkSupervisor(
    resolver: ref.read(endpointResolverProvider),
  );
  ref.onDispose(supervisor.dispose);
  return supervisor;
});

/// 代理设置（旁路由代理服务，需求 #13）。
final NotifierProvider<ProxySettingsNotifier, ProxySettings> proxySettingsProvider =
    NotifierProvider<ProxySettingsNotifier, ProxySettings>(ProxySettingsNotifier.new);

class ProxySettingsNotifier extends Notifier<ProxySettings> {
  @override
  ProxySettings build() {
    final Map<String, dynamic>? json =
        ref.watch(prefsStoreProvider).getJson(PrefKeys.proxySettings);
    return json == null ? const ProxySettings() : ProxySettings.fromJson(json);
  }

  /// 保存设置；[password] 传 null 表示不改动已保存的代理密码，传空串表示清除。
  Future<void> save(ProxySettings settings, {String? password}) async {
    await ref.read(prefsStoreProvider).setJson(PrefKeys.proxySettings, settings.toJson());
    if (password != null) {
      final SecureStore secure = ref.read(secureStoreProvider);
      if (password.isEmpty) {
        await secure.delete(SecureKeys.proxyPassword);
      } else {
        await secure.write(SecureKeys.proxyPassword, password);
      }
    }
    state = settings;
  }

  /// 安全存储中是否已有代理密码（只返回是否存在，不暴露内容）。
  Future<bool> hasPassword() async {
    final String? value = await ref.read(secureStoreProvider).read(SecureKeys.proxyPassword);
    return value != null && value.isNotEmpty;
  }
}

/// 代理运行时：内存持有代理设置与密码，统一套用到业务 Dio（需求 #13）。
final Provider<ProxyRuntime> proxyRuntimeProvider = Provider<ProxyRuntime>((Ref ref) {
  return ProxyRuntime(
    settings: ref.read(proxySettingsProvider),
    secure: ref.read(secureStoreProvider),
    apiDio: ref.read(apiClientProvider).raw,
  );
});

/// 主题模式（默认深色，跟随 App 内设置）。
final NotifierProvider<ThemeModeNotifier, ThemeMode> themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final String? value = ref.watch(prefsStoreProvider).getString(PrefKeys.themeMode);
    return switch (value) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  Future<void> setMode(ThemeMode mode) async {
    await ref.read(prefsStoreProvider).setString(PrefKeys.themeMode, mode.name);
    state = mode;
  }
}

/// 构建环境（dev / prod）。
final Provider<AppEnvironment> appEnvironmentProvider =
    Provider<AppEnvironment>((Ref ref) => AppEnvironment.current);