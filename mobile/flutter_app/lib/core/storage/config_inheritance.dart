import '../config/app_config.dart';
import '../network/url_utils.dart';
import 'prefs_store.dart';
import 'secure_store.dart';

/// 配置继承 / 迁移服务（需求 #17：版本更新迭代时，App 端已填入的配置自动继承）。
///
/// 设计要点：
/// - 使用独立的 schema 版本号（存于非敏感偏好）记录“用户配置已迁移到的版本”；
/// - 每条迁移只做“补充 / 改名 / 结构升级”，绝不删除或覆盖用户已填写的值；
/// - 缺少默认值的新键在这里补齐，已有值原样保留；
/// - 迁移过程幂等：可安全重复执行。
///
/// 新增一次配置结构变更时：
/// 1. 在 [AppConfig.configSchemaVersion] +1；
/// 2. 在 [_registry] 追加一条从旧版本到新版本的 [ConfigMigration]。
class ConfigInheritanceService {
  ConfigInheritanceService({required this.prefs, required this.secure});

  final PrefsStore prefs;
  final SecureStore secure;

  static const String schemaVersionKey = 'config.schemaVersion';
  static const String appVersionKey = 'config.lastAppVersion';

  /// 已持久化的配置 schema 版本；0 表示全新安装。
  int get storedSchemaVersion => prefs.getInt(schemaVersionKey) ?? 0;

  int get targetSchemaVersion => AppConfig.configSchemaVersion;

  /// 应用启动时调用：补齐默认值、按需执行迁移，返回本次执行结果。
  Future<ConfigInheritanceResult> initialize({String? appVersion}) async {
    final List<String> applied = <String>[];

    // 1) 补齐缺失默认值（不覆盖已有值）。
    await _ensureDefaults();

    // 2) 执行迁移链。
    final int from = storedSchemaVersion;
    if (from < targetSchemaVersion) {
      final List<ConfigMigration> pending = _registry
          .where((ConfigMigration m) => m.toVersion > from)
          .toList()
        ..sort((ConfigMigration a, ConfigMigration b) => a.toVersion.compareTo(b.toVersion));
      for (final ConfigMigration m in pending) {
        await m.run(prefs, secure);
        applied.add(m.id);
      }
      await prefs.setInt(schemaVersionKey, targetSchemaVersion);
    }

    // 3) 记录本次运行的 App 版本，供「关于 / 升级说明」比对使用。
    if (appVersion != null) {
      await prefs.setString(appVersionKey, appVersion);
    }

    return ConfigInheritanceResult(
      fromVersion: from,
      toVersion: targetSchemaVersion,
      appliedMigrations: applied,
    );
  }

  /// 首次安装或新增配置项时补齐默认值；已存在的键保持不变。
  Future<void> _ensureDefaults() async {
    if (!prefs.contains('link.mode')) {
      await prefs.setString('link.mode', 'auto');
    }
    if (!prefs.contains('theme.mode')) {
      await prefs.setString('theme.mode', 'dark');
    }
    // 代理设置整体以 JSON 存储；首次安装落一份显式基线，结构变更靠迁移链维护。
    if (!prefs.contains('proxy.settings')) {
      await prefs.setJson('proxy.settings', <String, dynamic>{
        'enabled': AppConfig.defaultProxyEnabled,
        'type': 'http',
        'host': '',
        'port': 0,
        'useAuth': false,
        'username': '',
      });
    }
    if (!prefs.contains('endpoint.lan')) {
      await prefs.setString('endpoint.lan', '');
    }
    if (!prefs.contains('endpoint.wan')) {
      await prefs.setString('endpoint.wan', '');
    }
    if (!prefs.contains('search.pageSize')) {
      await prefs.setInt('search.pageSize', 50);
    }
  }

  /// 迁移注册表：按 [ConfigMigration.toVersion] 升序执行。
  static final List<ConfigMigration> _registry = <ConfigMigration>[
    // v0 -> v1：首次引入 schema 版本，建立配置命名空间基线。
    ConfigMigration(
      id: '0_to_1_bootstrap',
      toVersion: 1,
      run: (PrefsStore prefs, SecureStore secure) async {
        // 无结构性变更，仅登记基线；保留既有键值。
      },
    ),
    // v1 -> v2：链路配置从单一 base url 升级为 LAN / WAN 双通道，旧值迁移到 LAN 通道。
    ConfigMigration(
      id: '1_to_2_dual_endpoint',
      toVersion: 2,
      run: (PrefsStore prefs, SecureStore secure) async {
        final String? legacy = prefs.getString('server.baseUrl');
        if (legacy != null && legacy.isNotEmpty && (prefs.getString('endpoint.lan') ?? '').isEmpty) {
          await prefs.setString('endpoint.lan', legacy);
        }
        await prefs.remove('server.baseUrl');
      },
    ),
    // v2 -> v3：新增代理与搜索分页配置，保持用户原值。
    ConfigMigration(
      id: '2_to_3_proxy_and_search',
      toVersion: 3,
      run: (PrefsStore prefs, SecureStore secure) async {
        if (!prefs.contains('proxy.host')) {
          await prefs.setString('proxy.host', '');
        }
        if (!prefs.contains('search.pageSize')) {
          await prefs.setInt('search.pageSize', 50);
        }
      },
    ),
    // v3 -> v4：MoviePilot 实例由单一地址升级为内网 / 外网双地址。
    // 只做「结构升级 + 补键」：把旧地址按内网/公网归到对应通道，绝不丢弃用户填过的地址。
    ConfigMigration(
      id: '3_to_4_moviepilot_dual_endpoint',
      toVersion: 4,
      run: (PrefsStore prefs, SecureStore secure) async {
        final Map<String, dynamic>? index = prefs.getJson('moviepilot.index');
        if (index == null) return;
        final Object? rawList = index['instances'];
        if (rawList is! List) return;

        bool changed = false;
        final List<Map<String, dynamic>> migrated = <Map<String, dynamic>>[];
        for (final Object? item in rawList) {
          if (item is! Map) continue;
          final Map<String, dynamic> instance = Map<String, dynamic>.from(item);
          final String legacy = instance['baseUrl'] as String? ?? '';
          final String lan = instance['lanBaseUrl'] as String? ?? '';
          final String wan = instance['wanBaseUrl'] as String? ?? '';
          if (lan.isEmpty && wan.isEmpty && legacy.isNotEmpty) {
            final Uri? uri = UrlUtils.normalize(legacy);
            if (uri != null) {
              final bool isLan = UrlUtils.isPrivateHost(uri.host);
              instance['lanBaseUrl'] = isLan ? uri.toString() : '';
              instance['wanBaseUrl'] = isLan ? '' : uri.toString();
              changed = true;
            }
          } else {
            if (!instance.containsKey('lanBaseUrl')) {
              instance['lanBaseUrl'] = lan;
              changed = true;
            }
            if (!instance.containsKey('wanBaseUrl')) {
              instance['wanBaseUrl'] = wan;
              changed = true;
            }
          }
          migrated.add(instance);
        }

        if (changed) {
          await prefs.setJson('moviepilot.index', <String, dynamic>{
            if (index['version'] != null) 'version': 2,
            'instances': migrated,
          });
        }
      },
    ),
  ];
}

/// 单条配置迁移：把配置从 [toVersion] - 1 升级到 [toVersion]。
class ConfigMigration {
  const ConfigMigration({required this.id, required this.toVersion, required this.run});

  final String id;
  final int toVersion;
  final Future<void> Function(PrefsStore prefs, SecureStore secure) run;
}

/// 配置继承执行结果。
class ConfigInheritanceResult {
  const ConfigInheritanceResult({
    required this.fromVersion,
    required this.toVersion,
    required this.appliedMigrations,
  });

  final int fromVersion;
  final int toVersion;
  final List<String> appliedMigrations;

  bool get isFreshInstall => fromVersion == 0;

  bool get didMigrate => appliedMigrations.isNotEmpty;
}