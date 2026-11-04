import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/monitor_dashboard.dart';
import '../network/url_utils.dart';

/// PT 监护室直连数据源（公开状态页 savept.icu）。
///
/// 为什么走直连：本仓库的 NAS 后端尚未实现，而监护室所需的数据（站点病危 / 站庆 /
/// 死亡 / 恢复公告）本身就是公开页面，App 直接读取即可用，且与参考实现
/// （MoviePilot 的 Vue-PT 监护室插件）取的是同一份公开数据。
///
/// 解析口径（与页面自带脚本一致）：
/// - 站点卡片来自 `a.card-link`，状态取 `data-status`（online / down / offline）；
/// - 顶部统计由 App 本地汇总（床位 / 健康 / 抢救 / 死亡 / 今日站庆）；
/// - 公告按分组标题（病危通知 / 恢复公告 / 站庆预告 / 死亡讣告）归类，
///   每条记录保留站点名、链接、紧跟其后的说明与链接 title。
class SavePtMonitorClient {
  SavePtMonitorClient(this._dio, {String? baseUrl}) : baseUrl = _normalizeBase(baseUrl);

  /// 归一化数据源基址：空值回落到默认地址，并去掉末尾斜杠。
  static String _normalizeBase(String? raw) {
    final String value = (raw ?? '').trim();
    if (value.isEmpty) return defaultBaseUrl;
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  /// 默认数据源地址（可在设置里改，便于镜像/自建替代）。
  static const String defaultBaseUrl = 'https://savept.icu';

  static const String _dashboardPath = '/';

  final Dio _dio;
  final String baseUrl;

  Uri get _base => Uri.parse(baseUrl);

  /// 拉取监护室首页（站点卡片 + 公告）。
  Future<MonitorDashboard> fetchDashboard({CancelToken? cancelToken}) async {
    final Uri target = UrlUtils.joinPath(_base, _dashboardPath);
    final Response<String> response = await _dio.getUri<String>(
      target,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: true,
        // 页面被 CDN / 防护页替换时也要拿到文本，交由解析层判断。
        validateStatus: (int? status) => status != null,
      ),
    );
    final String body = response.data ?? '';
    final int status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw SavePtException('监护室页面返回 HTTP $status（$target）');
    }
    final MonitorDashboard parsed = parseDashboard(body, sourceUrl: target);
    if (parsed.sites.isEmpty) {
      throw SavePtException(
        '监护室页面结构无法识别（$target 未解析到站点卡片，可能站点改版或返回了防护页）',
      );
    }
    return parsed;
  }

  /// 历史死亡事件（页面「历史事件」弹窗的第一页数据源）。
  Future<MonitorHistoryPage> fetchDeadHistory({int page = 1, CancelToken? cancelToken}) =>
      _fetchHistory('/api/history/dead', page: page, cancelToken: cancelToken);

  /// 历史站庆事件。
  Future<MonitorHistoryPage> fetchAnniversaryHistory({int page = 1, CancelToken? cancelToken}) =>
      _fetchHistory('/api/history/anniversary', page: page, cancelToken: cancelToken);

  Future<MonitorHistoryPage> _fetchHistory(
    String path, {
    required int page,
    CancelToken? cancelToken,
  }) async {
    final Uri target = UrlUtils.joinPath(_base, path).replace(
      queryParameters: <String, String>{'page': '$page'},
    );
    final Response<dynamic> response = await _dio.getUri<dynamic>(
      target,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.json,
        validateStatus: (int? status) => status != null,
      ),
    );
    final int status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw SavePtException('历史事件接口返回 HTTP $status（$target）');
    }
    return parseHistoryPage(response.data);
  }

  /// 解析监护室首页 HTML（纯函数，便于用真实页面样本做单元测试）。
  static MonitorDashboard parseDashboard(String htmlText, {Uri? sourceUrl, DateTime? now}) {
    final dom.Document document = html_parser.parse(htmlText);
    final List<MonitorSiteCard> sites = <MonitorSiteCard>[];
    for (final dom.Element link in document.querySelectorAll('a.card-link')) {
      final MonitorSiteCard? card = _parseSiteCard(link);
      if (card != null) sites.add(card);
    }
    final List<MonitorNoticeGroup> notices = <MonitorNoticeGroup>[];
    for (final dom.Element banner in document.querySelectorAll('.alert-banner')) {
      final MonitorNoticeGroup? group = _parseNoticeBanner(banner);
      if (group != null && group.items.isNotEmpty) notices.add(group);
    }
    return MonitorDashboard(
      sites: sites,
      notices: notices,
      fetchedAt: now ?? DateTime.now(),
      sourceUrl: sourceUrl?.toString() ?? '',
    );
  }

  /// 解析历史事件接口响应（`{items: [...], next_page, has_more}`）。
  static MonitorHistoryPage parseHistoryPage(Object? data) {
    if (data is! Map<String, dynamic>) {
      return const MonitorHistoryPage();
    }
    final List<MonitorHistoryEvent> items = (data['items'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(MonitorHistoryEvent.fromJson)
        .where((MonitorHistoryEvent e) => e.name.isNotEmpty || e.date.isNotEmpty)
        .toList(growable: false);
    return MonitorHistoryPage(
      items: items,
      nextPage: (data['next_page'] as num?)?.toInt(),
      hasMore: data['has_more'] as bool? ?? false,
    );
  }

  static MonitorSiteCard? _parseSiteCard(dom.Element link) {
    final String title = _clean(link.querySelector('.card-title')?.text ?? '');
    final String url = _clean(link.attributes['href'] ?? '');
    if (title.isEmpty && url.isEmpty) return null;

    final dom.Element? card = link.querySelector('.card');
    final String statusRaw = link.attributes['data-status'] ??
        (card?.classes.contains('is-closed') ?? false ? 'offline' : '');
    final String stripTitle = link.querySelector('.status-strip')?.attributes['title'] ?? '';
    final MonitorSiteState state = statusRaw.isNotEmpty
        ? MonitorSiteState.fromRaw(statusRaw)
        : _stateFromStripTitle(stripTitle);

    final dom.Element? anniversaryBadge = link.querySelector('.anniversary-badge');
    final bool anniversaryBadgeIsDead =
        (anniversaryBadge?.classes.contains('offline-duration-badge') ?? false);

    return MonitorSiteCard(
      name: title.isEmpty ? url : title,
      url: url,
      state: state,
      scope: MonitorSiteScope.fromRaw(link.attributes['data-type']),
      year: int.tryParse(link.attributes['data-year'] ?? ''),
      openDate: _clean(card?.attributes['data-opentime'] ?? ''),
      closeDate: _clean(card?.attributes['data-closetime'] ?? ''),
      aliveDays: _daysFromText(link.querySelector('.duration-badge')?.text),
      anniversaryCountdownDays:
          anniversaryBadgeIsDead ? null : _daysFromText(anniversaryBadge?.text),
      deadDays: anniversaryBadgeIsDead ? _daysFromText(anniversaryBadge?.text) : null,
      iconUrl: _clean(link.querySelector('img.site-icon')?.attributes['src'] ?? ''),
      searchKey: _clean(link.attributes['data-search'] ?? ''),
      anniversaryRecent: link.attributes['data-anniversary'] == 'yes',
    );
  }

  static MonitorSiteState _stateFromStripTitle(String title) {
    if (title.contains('运行')) return MonitorSiteState.online;
    if (title.contains('抢救')) return MonitorSiteState.down;
    if (title.contains('关站') || title.contains('死亡')) return MonitorSiteState.offline;
    return MonitorSiteState.unknown;
  }

  static MonitorNoticeGroup? _parseNoticeBanner(dom.Element banner) {
    final dom.Element? content = banner.querySelector('.alert-content');
    if (content == null) return null;

    // 分组标题在 `<strong>` 里，例如「病危通知：」。
    final String heading = _clean(content.querySelector('strong')?.text ?? '');
    final MonitorNoticeKind kind = MonitorNoticeKind.fromLabel(heading);

    final List<MonitorNoticeItem> items = <MonitorNoticeItem>[];
    final StringBuffer intro = StringBuffer();
    final StringBuffer note = StringBuffer();
    String currentName = '';
    String currentUrl = '';
    String currentTooltip = '';

    void flush() {
      if (currentName.isEmpty) return;
      items.add(
        MonitorNoticeItem(
          name: currentName,
          url: currentUrl,
          note: note.toString().trim(),
          tooltip: currentTooltip,
        ),
      );
      currentName = '';
      currentUrl = '';
      currentTooltip = '';
      note.clear();
    }

    void appendNote(String text) {
      final String value = _clean(text.replaceAll('|', ' '));
      if (value.isEmpty || value == heading) return;
      if (note.isNotEmpty) note.write(' ');
      note.write(value);
    }

    for (final dom.Node node in content.nodes) {
      if (node is dom.Element) {
        if (node.localName == 'strong') continue;
        if (node.classes.contains('site-tag')) {
          flush();
          currentName = _clean(node.text);
          currentUrl = _clean(node.attributes['href'] ?? '');
          currentTooltip = _clean(node.attributes['title'] ?? '');
        } else {
          appendNote(node.text);
        }
      } else {
        if (currentName.isEmpty) {
          final String value = _clean(node.text ?? '');
          if (value.isNotEmpty && value != heading) intro.write(value);
        } else {
          appendNote(node.text ?? '');
        }
      }
    }
    flush();

    if (items.isEmpty) return null;
    return MonitorNoticeGroup(kind: kind, items: items, intro: intro.toString().trim());
  }

  static int? _daysFromText(String? raw) {
    final String text = _clean(raw ?? '');
    if (text.isEmpty) return null;
    final RegExpMatch? match = RegExp(r'(\d+)').firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  static String _clean(String raw) =>
      raw.replaceAll('\u00A0', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 监护室数据源异常：带上目标地址与原因，便于界面直接展示。
class SavePtException implements Exception {
  const SavePtException(this.message);

  final String message;

  @override
  String toString() => message;
}