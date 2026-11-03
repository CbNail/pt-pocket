import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/moviepilot.dart';
import '../../features/downloaders/downloader_add_page.dart';
import '../../features/downloaders/downloader_detail_page.dart';
import '../../features/downloaders/downloaders_page.dart';
import '../../features/home/home_page.dart';
import '../../features/monitor/monitor_page.dart';
import '../../features/monitor/signin_page.dart';
import '../../features/profile/pt_data_page.dart';
import '../../features/profile/site_care_page.dart';
import '../../features/search/search_page.dart';
import '../../features/search/search_result_detail_page.dart';
import '../../features/settings/connection_settings_page.dart';
import '../../features/settings/major_sites_page.dart';
import '../../features/settings/mp_add_page.dart';
import '../../features/settings/mp_manage_page.dart';
import '../../features/settings/notify_page.dart';
import '../../features/settings/proxy_settings_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/shell/app_shell.dart';
import '../../features/sites/cookiecloud_import_page.dart';
import '../../features/sites/ptd_import_page.dart';
import '../../features/sites/site_add_page.dart';
import '../../features/sites/site_detail_page.dart';
import '../../features/sites/sites_page.dart';
import '../../features/sites/vaultwarden_login_page.dart';
import 'app_routes.dart';

/// 全局路由：五个主入口用 StatefulShellRoute.indexedStack 保留页面状态；
/// 次级页面（新增/详情/导入/登录/配置/资源情况）推入根导航器，全屏展示且不带底部导航。
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) => createAppRouter());

GlobalKey<NavigatorState> createRootNavigatorKey() => GlobalKey<NavigatorState>();

GoRouter createAppRouter({GlobalKey<NavigatorState>? navigatorKey}) {
  final GlobalKey<NavigatorState> rootKey = navigatorKey ?? createRootNavigatorKey();

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: AppRoutes.home,
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (BuildContext context, GoRouterState state, StatefulNavigationShell shell) =>
            AppShell(navigationShell: shell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.home,
                name: 'home',
                builder: (BuildContext context, GoRouterState state) => const HomePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.search,
                name: 'search',
                builder: (BuildContext context, GoRouterState state) => const SearchPage(),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.torrentDetail,
                    name: 'torrentDetail',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) {
                      final Object? extra = state.extra;
                      return SearchResultDetailPage(
                        item: extra is SearchResultItem ? extra : null,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.sites,
                name: 'sites',
                builder: (BuildContext context, GoRouterState state) => const SitesPage(),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.siteAdd,
                    name: 'siteAdd',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const SiteAddPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.siteDetail,
                    name: 'siteDetail',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) =>
                        SiteDetailPage(siteId: state.uri.queryParameters['siteId'] ?? ''),
                  ),
                  GoRoute(
                    path: AppRoutes.siteCookieCloud,
                    name: 'siteCookieCloud',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => CookieCloudImportPage(
                      siteId: state.uri.queryParameters['siteId'],
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.sitePtdImport,
                    name: 'sitePtdImport',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const PtdImportPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.siteVaultwarden,
                    name: 'siteVaultwarden',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => VaultwardenLoginPage(
                      siteId: state.uri.queryParameters['siteId'] ?? '',
                      initialUrl: state.uri.queryParameters['initialUrl'],
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.downloaders,
                name: 'downloaders',
                builder: (BuildContext context, GoRouterState state) => const DownloadersPage(),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.downloaderAdd,
                    name: 'downloaderAdd',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => DownloaderAddPage(
                      downloaderId: state.uri.queryParameters['downloaderId'],
                    ),
                  ),
                  GoRoute(
                    path: AppRoutes.downloaderDetail,
                    name: 'downloaderDetail',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => DownloaderDetailPage(
                      downloaderId: state.uri.queryParameters['downloaderId'] ?? '',
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: AppRoutes.settings,
                name: 'settings',
                builder: (BuildContext context, GoRouterState state) => const SettingsPage(),
                routes: <RouteBase>[
                  GoRoute(
                    path: AppRoutes.settingsConnection,
                    name: 'settingsConnection',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) =>
                        const ConnectionSettingsPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsProxy,
                    name: 'settingsProxy',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) =>
                        const ProxySettingsPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsMoviePilot,
                    name: 'settingsMoviePilot',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const MpManagePage(),
                    routes: <RouteBase>[
                      GoRoute(
                        path: AppRoutes.settingsMoviePilotAdd,
                        name: 'settingsMoviePilotAdd',
                        parentNavigatorKey: rootKey,
                        builder: (BuildContext context, GoRouterState state) => MpAddPage(
                          instanceId: state.uri.queryParameters['instanceId'],
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: AppRoutes.settingsPtData,
                    name: 'settingsPtData',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const PtDataPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsSiteCare,
                    name: 'settingsSiteCare',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const SiteCarePage(),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsMonitor,
                    name: 'settingsMonitor',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const MonitorPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsSignIn,
                    name: 'settingsSignIn',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const SignInPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsNotify,
                    name: 'settingsNotify',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) => const NotifyPage(),
                  ),
                  GoRoute(
                    path: AppRoutes.settingsMajorSites,
                    name: 'settingsMajorSites',
                    parentNavigatorKey: rootKey,
                    builder: (BuildContext context, GoRouterState state) =>
                        const MajorSitesPage(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}