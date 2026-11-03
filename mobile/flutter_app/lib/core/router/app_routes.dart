/// 应用路由路径注册表：所有页面路径的唯一来源，避免字符串散落。
///
/// 主导航采用五个底部入口（规格书 §4.1）：首页 / 搜索 / 站点 / 下载器 / 我的。
/// 次级页面以相对路径挂在所属分支下，并推入根导航器全屏展示。
library;

abstract final class AppRoutes {
  static const String home = '/home';
  static const String search = '/search';
  static const String sites = '/sites';
  static const String downloaders = '/downloaders';
  static const String settings = '/settings';

  // 站点模块子页面
  static const String siteAdd = 'add';
  static const String siteDetail = 'detail';
  static const String siteCookieCloud = 'cookiecloud';
  static const String sitePtdImport = 'ptd-import';
  static const String siteVaultwarden = 'vaultwarden';

  // 下载器模块子页面
  static const String downloaderAdd = 'add';
  static const String downloaderDetail = 'detail';

  // 搜索模块子页面
  static const String torrentDetail = 'torrent';

  // 「我的」子页面
  static const String settingsConnection = 'connection';
  static const String settingsProxy = 'proxy';
  static const String settingsMoviePilot = 'moviepilot';
  static const String settingsMoviePilotAdd = 'add';

  // 数据、状态与推送子页面
  static const String settingsPtData = 'ptdata';
  static const String settingsSiteCare = 'sitecare';
  static const String settingsMonitor = 'monitor';
  static const String settingsSignIn = 'signin';
  static const String settingsNotify = 'notify';
  static const String settingsMajorSites = 'major-sites';

  static const String siteAddPath = '$sites/$siteAdd';
  static const String siteCookieCloudPath = '$sites/$siteCookieCloud';
  static const String sitePtdImportPath = '$sites/$sitePtdImport';
  static const String downloaderAddPath = '$downloaders/$downloaderAdd';
  static const String settingsConnectionPath = '$settings/$settingsConnection';
  static const String settingsProxyPath = '$settings/$settingsProxy';
  static const String settingsMoviePilotPath = '$settings/$settingsMoviePilot';
  static const String settingsMoviePilotAddPath =
      '$settingsMoviePilotPath/$settingsMoviePilotAdd';
  static const String settingsPtDataPath = '$settings/$settingsPtData';
  static const String settingsSiteCarePath = '$settings/$settingsSiteCare';
  static const String settingsMonitorPath = '$settings/$settingsMonitor';
  static const String settingsSignInPath = '$settings/$settingsSignIn';
  static const String settingsNotifyPath = '$settings/$settingsNotify';
  static const String settingsMajorSitesPath = '$settings/$settingsMajorSites';

  /// 资源情况展示路径；结果对象通过路由 `extra` 传入，避免超长 query。
  static const String torrentDetailPath = '$search/$torrentDetail';

  /// 生成站点详情路径。
  static String siteDetailPath(String siteId) => '$sites/$siteDetail?siteId=$siteId';

  /// 生成下载器详情路径。
  static String downloaderDetailPath(String downloaderId) =>
      '$downloaders/$downloaderDetail?downloaderId=$downloaderId';

  /// 生成下载器编辑路径。
  static String downloaderEditPath(String downloaderId) =>
      '$downloaderAddPath?downloaderId=$downloaderId';

  /// 生成 MoviePilot 编辑路径。
  static String settingsMoviePilotEditPath(String instanceId) =>
      '$settingsMoviePilotAddPath?instanceId=$instanceId';

  /// 生成站点 CookieCloud 导入路径（可带目标站点）。
  static String siteCookieCloudPathFor({String? siteId}) {
    if (siteId == null || siteId.isEmpty) return siteCookieCloudPath;
    return '$siteCookieCloudPath?siteId=$siteId';
  }

  /// 生成内置 WebView 登录路径（可带目标站点与初始地址）。
  static String siteVaultwardenPath({String siteId = '', String? initialUrl}) {
    final StringBuffer buffer = StringBuffer('$sites/$siteVaultwarden');
    final List<String> params = <String>[];
    if (siteId.isNotEmpty) params.add('siteId=$siteId');
    if (initialUrl != null && initialUrl.isNotEmpty) {
      params.add('initialUrl=${Uri.encodeQueryComponent(initialUrl)}');
    }
    if (params.isNotEmpty) buffer.write('?${params.join('&')}');
    return buffer.toString();
  }
}