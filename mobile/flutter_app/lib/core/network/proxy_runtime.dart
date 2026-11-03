import 'package:dio/dio.dart';

import '../models/proxy_settings.dart';
import '../storage/app_keys.dart';
import '../storage/secure_store.dart';
import 'proxy_manager.dart';

/// 代理运行时：在内存中持有代理设置与代理密码，统一把代理套用到各业务 Dio。
///
/// 密码只在启动与保存设置时从安全存储读取一次，避免每次请求都访问安全存储；
/// 需求 13：App 自身可通过自建旁路由提供的代理服务访问外网站点。
class ProxyRuntime {
  ProxyRuntime({
    required this.settings,
    required this.secure,
    required this.apiDio,
  });

  /// 当前代理设置；改变后由 [update] 就地更新并立即重新套用。
  ProxySettings settings;

  final SecureStore secure;
  final Dio apiDio;

  String? _password;
  bool _passwordLoaded = false;

  /// 代理密码是否已从安全存储加载（未加载时不注入代理认证）。
  bool get passwordLoaded => _passwordLoaded;

  /// 启动时调用：读取代理密码并立即套用到 API 客户端。
  Future<void> load() async {
    _password = await secure.read(SecureKeys.proxyPassword);
    _passwordLoaded = true;
    apply(apiDio);
  }

  /// 保存代理设置后调用：更新内存设置与密码并重新套用。
  ///
  /// [password] 传 `null` 表示沿用安全存储中的值；传空串表示清除密码。
  Future<void> update(ProxySettings next, {String? password}) async {
    settings = next;
    if (password != null) {
      _password = password.isEmpty ? null : password;
      _passwordLoaded = true;
    } else {
      _password = await secure.read(SecureKeys.proxyPassword);
      _passwordLoaded = true;
    }
    apply(apiDio);
  }

  /// 把当前代理设置套用到指定 Dio（探测、CookieCloud 等业务实例）。
  void apply(Dio dio) =>
      ProxyManager.apply(dio, settings, password: _passwordLoaded ? _password : null);

  /// 统一构造业务 Dio（自动套用代理）。
  Dio createDio({Duration? connectTimeout, Duration? receiveTimeout}) {
    final Dio dio = Dio();
    if (connectTimeout != null) dio.options.connectTimeout = connectTimeout;
    if (receiveTimeout != null) dio.options.receiveTimeout = receiveTimeout;
    apply(dio);
    return dio;
  }
}