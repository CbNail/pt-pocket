import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/moviepilot.dart';
import '../models/pt_site.dart';
import '../network/url_utils.dart';

/// 站点直连失败原因分类：界面据此给出可执行提示，而不是笼统「失败」。
enum SiteFetchFailureKind {
  /// 未配置凭据（需要 Cookie / Passkey / API Key）。
  missingCredential('缺少凭据'),

  /// 凭据失效（站点把我们踢回登录页）。
  unauthorized('登录态失效'),

  /// 站点限流 / 需要验证码。
  rateLimited('被限流'),

  /// 网络层失败（超时 / 域名解析 / 证书）。
  network('网络不可达'),

  /// 页面结构无法识别（站点改版或非 NexusPHP 结构）。
  unparsed('页面结构未识别'),

  /// 其它未知失败。
  unknown('未知失败');

  const SiteFetchFailureKind(this.label);

  final String label;
}

/// 站点直连异常：带分类、目标地址与原因，界面可直接展示。
class SiteFetchException implements Exception {
  const SiteFetchException({
    required this.kind,
    required this.message,
    this.target = '',
    this.statusCode,
  });

  final SiteFetchFailureKind kind;
  final String message;
  final String target;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 站点用户页解析结果（NexusPHP 口径）。
///
/// 只承载页面确实给出的字段；没解析到的字段保持 `null` 并记入 [missing]，
/// 界面据此显示「数据未提供」，而不是拿 0 冒充。
class SiteUserSnapshot {
  const SiteUserSnapshot({
    required this.siteId,
    required this.siteName,
    this.username = '',
    this.userClass = '',
    this.userId = '',
    this.uploadedBytes,
    this.downloadedBytes,
    this.ratio,
    this.infiniteRatio = false,
    this.bonus,
    this.seedingCount,
    this.leechingCount,
    this.seedingSizeBytes,
    this.invites,
    this.unreadMessages,
    this.hrCount,
    this.hrSummary = '',
    this.connections,
    this.joinDate,
    this.fetchedAt,
    this.missing = const <String>[],
  });

  final String siteId;
  final String siteName;
  final String username;
  final String userClass;
  final String userId;
  final int? uploadedBytes;
  final int? downloadedBytes;

  /// 分享率；[infiniteRatio] 为真时站点给的是「∞」。
  final double? ratio;
  final bool infiniteRatio;
  final int? bonus;
  final int? seedingCount;
  final int? leechingCount;
  final int? seedingSizeBytes;
  final int? invites;
  final int? unreadMessages;
  final int? hrCount;
  final String hrSummary;
  final int? connections;
  final DateTime? joinDate;
  final DateTime? fetchedAt;

  /// 未在页面上找到的字段名（用于界面「数据未提供」标注）。
  final List<String> missing;

  double? get effectiveRatio {
    if (infiniteRatio) return null;
    if (ratio != null) return ratio;
    final int? up = uploadedBytes;
    final int? down = downloadedBytes;
    if (up == null || down == null || down <= 0) return null;
    return up / down;
  }

  String get ratioLabel {
    if (infiniteRatio) return '∞';
    final double? value = effectiveRatio;
    return value == null ? '—' : value.toStringAsFixed(2);
  }

  bool get isEmpty => username.isEmpty && uploadedBytes == null && downloadedBytes == null;

  /// 是否有可入库的核心数值（用于本地历史采样 / 时魔估算）。
  bool get hasCoreNumbers =>
      uploadedBytes != null || downloadedBytes != null || bonus != null;
}

/// 站点页直连客户端（NexusPHP 结构）。
///
/// 职责：
/// - 带 Cookie 抓站点用户页（`index.php`），解析用户名 / 等级 / 上传下载 / 分享率 /
///   魔力值 / 做种 / 邀请 / 邮件 / H&R / 注册时间；
/// - 带 Cookie 抓站内搜索页（`torrents.php?search=...`），解析种子列表。
///
/// 约定（与仓库原有架构的关系）：本类属于「App 直连数据源」，
/// NAS 后端可用时仍可回退到后端接口；两条路径产出同一套模型。
class NexusPhpClient {
  NexusPhpClient(this._dio);

  final Dio _dio;

  static const Duration defaultTimeout = Duration(seconds: 15);

  /// 抓取站点用户页并解析。
  Future<SiteUserSnapshot> fetchUserSnapshot(
    PtSite site, {
    Map<String, dynamic>? credential,
    CancelToken? cancelToken,
  }) async {
    final Uri? base = UrlUtils.normalize(site.baseUrl);
    if (base == null) {
      throw const SiteFetchException(
        kind: SiteFetchFailureKind.unparsed,
        message: '站点地址不合法，请先修正站点地址',
      );
    }
    final String cookie = cookieOf(credential);
    if (cookie.isEmpty) {
      throw SiteFetchException(
        kind: SiteFetchFailureKind.missingCredential,
        message: '${site.name} 未保存 Cookie，无法读取个人数据；请在站点里登录或导入 CookieCloud',
        target: base.toString(),
      );
    }

    final Uri target = UrlUtils.joinPath(base, '/index.php');
    final String html = await _getText(
      target,
      cookie: cookie,
      cancelToken: cancelToken,
      siteName: site.name,
    );
    return NexusPhpUserParser.parse(
      html,
      siteId: site.id,
      siteName: site.name,
      baseUrl: base.toString(),
    );
  }

  /// 站点资源列表（`torrents.php` 不带关键词 = 该站最新资源）。
  Future<SearchPageResult> browse(
    PtSite site, {
    required int page,
    required int pageSize,
    Map<String, dynamic>? credential,
    PromotionFilter promotion = PromotionFilter.all,
    CancelToken? cancelToken,
  }) =>
      search(
        site,
        keyword: '',
        page: page,
        pageSize: pageSize,
        credential: credential,
        promotion: promotion,
        cancelToken: cancelToken,
      );

  /// 站内搜索（逐站下发，一页结果）；[keyword] 为空时等价于浏览该站资源列表。
  Future<SearchPageResult> search(
    PtSite site, {
    required String keyword,
    required int page,
    required int pageSize,
    Map<String, dynamic>? credential,
    PromotionFilter promotion = PromotionFilter.all,
    CancelToken? cancelToken,
  }) async {
    final Uri? base = UrlUtils.normalize(site.baseUrl);
    if (base == null) {
      throw const SiteFetchException(
        kind: SiteFetchFailureKind.unparsed,
        message: '站点地址不合法，请先修正站点地址',
      );
    }
    final String cookie = cookieOf(credential);
    if (cookie.isEmpty) {
      throw SiteFetchException(
        kind: SiteFetchFailureKind.missingCredential,
        message: '${site.name} 未保存 Cookie，读取站点资源需要登录态；'
            '请在站点里登录或导入 CookieCloud / PTD 备份',
        target: base.toString(),
      );
    }

    final String trimmed = keyword.trim();
    final Map<String, String> query = <String, String>{
      if (trimmed.isNotEmpty) ...<String, String>{'search': trimmed, 'notnewword': '1'},
      if (page > 1) 'page': '$page',
    };
    final Uri target = UrlUtils.joinPath(base, '/torrents.php')
        .replace(queryParameters: query);
    final String html = await _getText(
      target,
      cookie: cookie,
      cancelToken: cancelToken,
      siteName: site.name,
    );
    return NexusPhpSearchParser.parse(
      html,
      siteId: site.id,
      siteName: site.name,
      baseUrl: base.toString(),
      page: page,
      pageSize: pageSize,
      promotion: promotion,
      passkey: passkeyOf(credential, cookie),
    );
  }

  /// 从凭据里取 Cookie 值（支持 `type=cookie` 与直接给 `cookie` 字段两种形态）。
  static String cookieOf(Map<String, dynamic>? credential) {
    if (credential == null) return '';
    final Object? raw = credential['cookie'] ?? credential['cookies'];
    return raw == null ? '' : raw.toString().trim();
  }

  /// 从凭据里取 Passkey（下载链接需要）。
  static String passkeyOf(Map<String, dynamic>? credential, String cookie) {
    final Object? raw = credential?['passkey'];
    final String direct = raw == null ? '' : raw.toString().trim();
    if (direct.isNotEmpty) return direct;
    final RegExpMatch? match = RegExp(r'passkey=([A-Za-z0-9]+)').firstMatch(cookie);
    return match?.group(1) ?? '';
  }

  Future<String> _getText(
    Uri target, {
    required String cookie,
    required String siteName,
    CancelToken? cancelToken,
  }) async {
    try {
      final Response<String> response = await _dio.getUri<String>(
        target,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          sendTimeout: defaultTimeout,
          receiveTimeout: defaultTimeout,
          headers: <String, dynamic>{
            'Cookie': cookie,
            'Accept': 'text/html,application/xhtml+xml',
            // 少数站点会按 UA 返回不同页面；用常见浏览器 UA 拿到标准结构。
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
          },
          validateStatus: (int? status) => status != null,
        ),
      );
      final int status = response.statusCode ?? 0;
      final String body = response.data ?? '';
      if (status == 401 || status == 403) {
        throw SiteFetchException(
          kind: SiteFetchFailureKind.unauthorized,
          message: '$siteName 返回 HTTP $status：Cookie 可能已失效，请重新登录站点或导入 Cookie',
          target: target.toString(),
          statusCode: status,
        );
      }
      if (status == 429 || status == 503) {
        throw SiteFetchException(
          kind: SiteFetchFailureKind.rateLimited,
          message: '$siteName 返回 HTTP $status：站点正在限流，稍后再试',
          target: target.toString(),
          statusCode: status,
        );
      }
      if (status < 200 || status >= 300) {
        throw SiteFetchException(
          kind: SiteFetchFailureKind.unknown,
          message: '$siteName 返回 HTTP $status（$target）',
          target: target.toString(),
          statusCode: status,
        );
      }
      if (NexusPhpUserParser.looksLikeLoginPage(body)) {
        throw SiteFetchException(
          kind: SiteFetchFailureKind.unauthorized,
          message: '$siteName 跳转到登录页：Cookie 已失效或缺少必要字段，请重新登录站点',
          target: target.toString(),
        );
      }
      return body;
    } on DioException catch (error) {
      throw SiteFetchException(
        kind: SiteFetchFailureKind.network,
        message: describeNetworkFailure(siteName, target, error),
        target: target.toString(),
        statusCode: error.response?.statusCode,
      );
    }
  }

  /// 网络层失败归因（超时 / 域名解析 / 证书）。
  static String describeNetworkFailure(String siteName, Uri target, DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.receiveTimeout:
        return '$siteName 连接超时：$target 在超时内没有响应（可能站点被墙、端口不通或需要代理）';
      case DioExceptionType.badCertificate:
        return '$siteName 证书校验失败：$target 的证书不受信任';
      case DioExceptionType.connectionError:
        return '$siteName 无法建立连接：$target 域名解析失败或端口未开放（${error.message ?? ''}）';
      default:
        return '$siteName 请求失败：$target（${error.message ?? error.type.name}）';
    }
  }
}

/// NexusPHP 用户页解析器（纯函数，便于用真实页面片段做单元测试）。
abstract final class NexusPhpUserParser {
  /// 判定页面是否是登录页（Cookie 失效时站点会跳转过来）。
  static bool looksLikeLoginPage(String html) {
    final String lower = html.toLowerCase();
    if (!lower.contains('login.php') && !lower.contains('takelogin')) return false;
    final bool hasPasswordField = lower.contains('name="password"') ||
        lower.contains("name='password'") ||
        lower.contains('name=password');
    final bool hasUserNameField = lower.contains('name="username"') ||
        lower.contains("name='username'") ||
        lower.contains('name=username');
    final bool hasUserData = lower.contains('分享率') || lower.contains('ratio');
    return hasPasswordField && hasUserNameField && !hasUserData;
  }

  static SiteUserSnapshot parse(
    String html, {
    required String siteId,
    required String siteName,
    String baseUrl = '',
    DateTime? now,
  }) {
    final dom.Document document = html_parser.parse(html);
    final String text = _flatten(document.body?.text ?? html);
    final List<String> missing = <String>[];

    final (String username, String userId) = _findUserName(document);
    final String userClass = _findUserClass(text);

    final int? uploaded = _bytesAfter(text, <String>['上传量', '上传', '已上传', 'Uploaded']);
    final int? downloaded = _bytesAfter(text, <String>['下载量', '下载', '已下载', 'Downloaded']);
    final (double? ratio, bool infinite) = _ratioAfter(text);

    final int? bonus = _numberAfter(text, <String>['魔力值', '魔力', '积分', 'Bonus']);
    final int? seeding = _numberAfter(text, <String>['做种中', '做种数', '保种数', 'Seeding']);
    final int? leeching = _numberAfter(text, <String>['下载中', '下载数', 'Leeching']);
    final int? seedingSize = _bytesAfter(text, <String>['做种体积', '做种量', '保种体积', 'Seeding size']);
    final int? invites = _numberAfter(text, <String>['邀请名额', '邀请数', '邀请', 'Invites']);
    final int? mails = _numberAfter(text, <String>['未读消息', '未读邮件', '站内信', '新消息', 'Messages']);
    final (int? hr, String hrSummary) = _hrAfter(text);
    final DateTime? joinDate = _dateAfter(text, <String>['注册时间', '注册日期', '加入时间', '加入日期', '注册于']);

    if (username.isEmpty) missing.add('用户名');
    if (userClass.isEmpty) missing.add('等级');
    if (uploaded == null) missing.add('上传量');
    if (downloaded == null) missing.add('下载量');
    if (ratio == null && !infinite) missing.add('分享率');
    if (bonus == null) missing.add('魔力值');
    if (seeding == null) missing.add('做种数');
    if (joinDate == null) missing.add('注册时间');

    return SiteUserSnapshot(
      siteId: siteId,
      siteName: siteName,
      username: username,
      userClass: userClass,
      userId: userId,
      uploadedBytes: uploaded,
      downloadedBytes: downloaded,
      ratio: ratio,
      infiniteRatio: infinite,
      bonus: bonus,
      seedingCount: seeding,
      leechingCount: leeching,
      seedingSizeBytes: seedingSize,
      invites: invites,
      unreadMessages: mails,
      hrCount: hr,
      hrSummary: hrSummary,
      joinDate: joinDate,
      fetchedAt: now ?? DateTime.now(),
      missing: missing,
    );
  }

  /// 用户名与 uid：取页面上第一个指向 `userdetails.php?id=` 的短文本链接。
  static (String, String) _findUserName(dom.Document document) {
    for (final dom.Element anchor in document.querySelectorAll('a[href*="userdetails.php"]')) {
      final String href = anchor.attributes['href'] ?? '';
      final RegExpMatch? idMatch = RegExp(r'id=(\d+)').firstMatch(href);
      final String name = _flatten(anchor.text);
      if (idMatch != null && name.isNotEmpty && name.length <= 24) {
        return (name, idMatch.group(1) ?? '');
      }
    }
    return ('', '');
  }

  /// 等级：优先「等级」标签，其次匹配 NexusPHP 常见等级名。
  static String _findUserClass(String text) {
    final RegExpMatch? labelled = RegExp(
      r'(?:用户等级|等级|会员等级|级别)\s*[:：]?\s*([A-Za-z][A-Za-z ]{2,20}|[\u4e00-\u9fa5]{2,10})',
    ).firstMatch(text);
    if (labelled != null) {
      final String value = labelled.group(1)?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    for (final String name in knownUserClasses) {
      if (RegExp('(^|[^A-Za-z])${RegExp.escape(name)}([^A-Za-z]|\$)', caseSensitive: false)
          .hasMatch(text)) {
        return name;
      }
    }
    return '';
  }

  /// NexusPHP 常见等级名（用于从页面文本里识别当前等级）。
  static const List<String> knownUserClasses = <String>[
    'Nexus Master',
    'Ultimate User',
    'Extreme User',
    'Veteran User',
    'Insane User',
    'Crazy User',
    'Elite User',
    'Power User',
    'User',
    '初游者',
    '初级用户',
    '中级用户',
    '高级用户',
    '骨灰级用户',
    '退休者',
    'VIP',
    'Uploader',
    'Moderator',
    'Administrator',
  ];

  static (int?, String) _hrAfter(String text) {
    final RegExpMatch? match =
        RegExp(r'(?:H&R|HR|Hit\s*and\s*Run)[^0-9]{0,24}(\d+)\s*[/／]\s*(\d+)\s*[/／]\s*(\d+)')
            .firstMatch(text);
    if (match != null) {
      final int pending = int.tryParse(match.group(1) ?? '') ?? 0;
      return (pending, '${match.group(1)}/${match.group(2)}/${match.group(3)}');
    }
    return (null, '');
  }

  static int? _bytesAfter(String text, List<String> labels) {
    for (final String label in labels) {
      final RegExp pattern = RegExp(
        '${RegExp.escape(label)}[^0-9]{0,24}([\\d.,]+)\\s*(PB|TB|GB|MB|KB|PiB|TiB|GiB|MiB|KiB|[PTGMK])B?',
        caseSensitive: false,
      );
      final RegExpMatch? match = pattern.firstMatch(text);
      if (match != null) {
        final int? value = bytesFrom(match.group(1) ?? '', match.group(2) ?? '');
        if (value != null) return value;
      }
    }
    return null;
  }

  static int? _numberAfter(String text, List<String> labels) {
    for (final String label in labels) {
      final RegExp pattern = RegExp(
        '${RegExp.escape(label)}[^0-9]{0,24}([\\d.,]+)',
        caseSensitive: false,
      );
      final RegExpMatch? match = pattern.firstMatch(text);
      if (match != null) {
        // 千分位逗号要去掉；小数点要保留语义（如「86895.0」不能读成 868950）。
        final num? value = num.tryParse((match.group(1) ?? '').replaceAll(',', ''));
        if (value != null) return value.toInt();
      }
    }
    return null;
  }

  static (double?, bool) _ratioAfter(String text) {
    for (final String label in <String>['分享率', 'Ratio']) {
      final RegExp pattern = RegExp(
        '${RegExp.escape(label)}[^0-9∞]{0,24}(∞|inf|Inf|无限|[\\d.]+)',
        caseSensitive: false,
      );
      final RegExpMatch? match = pattern.firstMatch(text);
      if (match != null) {
        final String raw = (match.group(1) ?? '').trim();
        if (raw == '∞' || raw.toLowerCase() == 'inf' || raw == '无限') {
          return (null, true);
        }
        final double? value = double.tryParse(raw);
        if (value != null) return (value, false);
      }
    }
    return (null, false);
  }

  static DateTime? _dateAfter(String text, List<String> labels) {
    for (final String label in labels) {
      final RegExpMatch? match = RegExp(
        '${RegExp.escape(label)}[^0-9]{0,12}(\\d{4})[-/年](\\d{1,2})[-/月](\\d{1,2})'
        '(?:\\s*(\\d{1,2}):(\\d{1,2})(?::(\\d{1,2}))?)?',
      ).firstMatch(text);
      if (match != null) {
        final int? year = int.tryParse(match.group(1) ?? '');
        final int? month = int.tryParse(match.group(2) ?? '');
        final int? day = int.tryParse(match.group(3) ?? '');
        if (year == null || month == null || day == null) continue;
        return DateTime(
          year,
          month,
          day,
          int.tryParse(match.group(4) ?? '') ?? 0,
          int.tryParse(match.group(5) ?? '') ?? 0,
          int.tryParse(match.group(6) ?? '') ?? 0,
        );
      }
    }
    return null;
  }

  /// 「1.23 GB」→ 字节数（1024 进制；单位缩写按最常见的 K/M/G/T/P 处理）。
  static int? bytesFrom(String number, String unit) {
    final double? value = double.tryParse(number.replaceAll(',', '').trim());
    if (value == null) return null;
    final String u = unit.toUpperCase().replaceAll('I', '');
    final int factor = switch (u) {
      'P' || 'PB' => 1 << 50,
      'T' || 'TB' => 1 << 40,
      'G' || 'GB' => 1 << 30,
      'M' || 'MB' => 1 << 20,
      'K' || 'KB' => 1 << 10,
      _ => 1,
    };
    return (value * factor).round();
  }

  static String _flatten(String raw) =>
      raw.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// NexusPHP 搜索页解析器（纯函数）。
abstract final class NexusPhpSearchParser {
  static SearchPageResult parse(
    String html, {
    required String siteId,
    required String siteName,
    String baseUrl = '',
    required int page,
    required int pageSize,
    PromotionFilter promotion = PromotionFilter.all,
    String passkey = '',
  }) {
    final dom.Document document = html_parser.parse(html);
    final List<dom.Element> rows = _resultRows(document);
    final List<SearchResultItem> items = <SearchResultItem>[];
    final Set<String> seen = <String>{};

    for (final dom.Element row in rows) {
      final SearchResultItem? item = _parseRow(
        row,
        siteId: siteId,
        siteName: siteName,
        baseUrl: baseUrl,
        passkey: passkey,
      );
      if (item == null) continue;
      if (!seen.add(item.id)) continue;
      if (!_promotionMatches(item.promotion, promotion)) continue;
      items.add(item);
    }

    final String text = document.body?.text ?? html;
    if (items.isEmpty && !_looksLikeEmptyResult(text)) {
      throw SiteFetchException(
        kind: SiteFetchFailureKind.unparsed,
        message: '$siteName 搜索页结构未识别：未找到结果表，可能是站点改版或非 NexusPHP 结构',
        target: baseUrl,
      );
    }

    final bool hasMore = items.length >= pageSize || _hasNextPage(document);
    return SearchPageResult(
      items: items,
      page: page,
      pageSize: pageSize,
      hasMore: hasMore,
    );
  }

  static bool _promotionMatches(PromotionType value, PromotionFilter filter) {
    return switch (filter) {
      PromotionFilter.all => true,
      PromotionFilter.free => value == PromotionType.free || value == PromotionType.twoXFree,
      PromotionFilter.twoXFree => value == PromotionType.twoXFree,
      PromotionFilter.half => value == PromotionType.half || value == PromotionType.twoXHalf,
    };
  }

  static List<dom.Element> _resultRows(dom.Document document) {
    final List<dom.Element> rows = <dom.Element>[];
    for (final dom.Element table in document.querySelectorAll('table')) {
      final String id = table.attributes['id'] ?? '';
      if (!table.classes.contains('torrents') && id != 'torrenttable' && id != 'torrenttable-main') {
        continue;
      }
      for (final dom.Element row in table.querySelectorAll('tr')) {
        if (_detailsAnchor(row) != null) rows.add(row);
      }
    }
    if (rows.isNotEmpty) return rows;
    // 兜底：有些站点搜索页直接用 tr 平铺，没有固定表 id。
    for (final dom.Element row in document.querySelectorAll('tr')) {
      if (_detailsAnchor(row) != null) rows.add(row);
    }
    return rows;
  }

  static dom.Element? _detailsAnchor(dom.Element row) {
    for (final dom.Element anchor in row.querySelectorAll('a[href*="details.php"]')) {
      final String href = anchor.attributes['href'] ?? '';
      if (RegExp(r'id=\d+').hasMatch(href)) return anchor;
    }
    return null;
  }

  static SearchResultItem? _parseRow(
    dom.Element row, {
    required String siteId,
    required String siteName,
    required String baseUrl,
    required String passkey,
  }) {
    final dom.Element? anchor = _detailsAnchor(row);
    if (anchor == null) return null;
    final String href = anchor.attributes['href'] ?? '';
    final RegExpMatch? idMatch = RegExp(r'id=(\d+)').firstMatch(href);
    final String id = idMatch?.group(1) ?? '';
    if (id.isEmpty) return null;

    final String title = _rowTitle(row, anchor, id);
    if (title.isEmpty) return null;

    final String rowText = NexusPhpUserParser._flatten(row.text);
    final (int sizeBytes, DateTime? published) = _sizeAndDate(row, rowText);
    final (int seeders, int leechers) = _seedersLeechers(row, rowText);
    final PromotionType promotion = _promotionOf(row);
    final String category = _categoryOf(row);

    final Uri? base = baseUrl.isEmpty ? null : Uri.tryParse(baseUrl);
    String downloadUrl = '';
    if (base != null) {
      String suffix = '/download.php?id=$id';
      if (passkey.isNotEmpty) suffix = '$suffix&passkey=$passkey';
      downloadUrl = UrlUtils.joinPath(base, suffix).toString();
    }

    return SearchResultItem(
      id: id,
      title: title,
      siteId: siteId,
      siteName: siteName,
      subtitle: category,
      sizeBytes: sizeBytes,
      seeders: seeders,
      leechers: leechers,
      publishedAt: published,
      promotion: promotion,
      downloadUrl: downloadUrl,
      detailUrl: base == null ? href : UrlUtils.joinPath(base, '/details.php?id=$id').toString(),
      category: category,
      source: 'site',
    );
  }

  static String _rowTitle(dom.Element row, dom.Element anchor, String id) {
    final String attr = anchor.attributes['title'] ?? '';
    if (attr.trim().isNotEmpty && !attr.contains('details.php')) return attr.trim();
    final String text = NexusPhpUserParser._flatten(anchor.text);
    if (text.isNotEmpty) return text;
    // 标题在相邻单元格里（详情链接只有图片时）。
    for (final dom.Element other in row.querySelectorAll('a[href*="details.php"]')) {
      final String value = NexusPhpUserParser._flatten(other.text);
      if (value.isNotEmpty && !value.startsWith('[')) return value;
    }
    return '';
  }

  static (int, DateTime?) _sizeAndDate(dom.Element row, String rowText) {
    int size = 0;
    for (final dom.Element cell in row.querySelectorAll('td')) {
      final String text = NexusPhpUserParser._flatten(cell.text);
      if (text.isEmpty) continue;
      final RegExpMatch? match = RegExp(
        r'^([\d.,]+)\s*(PB|TB|GB|MB|KB|B|PiB|TiB|GiB|MiB|KiB|[PTGMK])\b',
        caseSensitive: false,
      ).firstMatch(text);
      if (match != null) {
        final int? value =
            NexusPhpUserParser.bytesFrom(match.group(1) ?? '', match.group(2) ?? '');
        if (value != null && value > size) size = value;
      }
    }
    final RegExpMatch? dateMatch =
        RegExp(r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})(?::(\d{2}))?').firstMatch(rowText);
    DateTime? published;
    if (dateMatch != null) {
      published = DateTime.tryParse(
        '${dateMatch.group(1)} ${dateMatch.group(2)}:${dateMatch.group(3) ?? '00'}',
      );
    }
    return (size, published);
  }

  static (int, int) _seedersLeechers(dom.Element row, String rowText) {
    final List<int> peers = <int>[];
    for (final dom.Element anchor in row.querySelectorAll('a[href*="peers.php"]')) {
      final String text = NexusPhpUserParser._flatten(anchor.text);
      final int? value = int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), ''));
      if (value != null) peers.add(value);
    }
    if (peers.length >= 2) {
      return (peers[0], peers[1]);
    }
    // 兜底：取行尾两个独立数字（NexusPHP 的做种 / 下载列通常在最后）。
    final List<int> tail = <int>[];
    for (final RegExpMatch match
        in RegExp(r'(?:^|\s)(\d{1,5})(?=\s|$)').allMatches(rowText)) {
      tail.add(int.parse(match.group(1) ?? '0'));
    }
    if (tail.length >= 2) {
      return (tail[tail.length - 2], tail[tail.length - 1]);
    }
    return (peers.isEmpty ? 0 : peers.first, 0);
  }

  static PromotionType _promotionOf(dom.Element row) {
    final String html = row.outerHtml.toLowerCase();
    // NexusPHP 用图标 class 标记促销；顺序从最优惠到最普通，避免 2×免费被判成免费。
    if (html.contains('pro_free2up') || html.contains('2xfree') || html.contains('2x免费')) {
      return PromotionType.twoXFree;
    }
    if (html.contains('pro_2up50') || html.contains('2x50')) return PromotionType.twoXHalf;
    if (html.contains('pro_2up') || html.contains('2xup') || html.contains('2x上传')) {
      return PromotionType.twoXUp;
    }
    if (html.contains('pro_free') || html.contains('免费')) return PromotionType.free;
    if (html.contains('pro_50pct') || html.contains('50%')) return PromotionType.half;
    if (html.contains('pro_30pct') || html.contains('30%')) return PromotionType.other;
    return PromotionType.none;
  }

  static String _categoryOf(dom.Element row) {
    for (final dom.Element anchor in row.querySelectorAll('a[href*="torrents.php?cat="]')) {
      final String text = NexusPhpUserParser._flatten(anchor.text);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static bool _hasNextPage(dom.Document document) {
    for (final dom.Element anchor in document.querySelectorAll('a')) {
      final String text = NexusPhpUserParser._flatten(anchor.text);
      if (text.contains('下一页') || text.toLowerCase() == 'next') {
        final String href = anchor.attributes['href'] ?? '';
        if (href.contains('page=') || href.contains('pagenumber=')) return true;
      }
    }
    return false;
  }

  static bool _looksLikeEmptyResult(String text) {
    const List<String> markers = <String>[
      '没有找到',
      '没有匹配',
      '没有种子',
      '结果为空',
      'no torrents',
      'no results',
      'nothing found',
    ];
    final String lower = text.toLowerCase();
    return markers.any(lower.contains);
  }
}