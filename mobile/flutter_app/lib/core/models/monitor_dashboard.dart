/// PT 监护室（savept.icu）直连数据模型。
///
/// 口径来源：本站是公开的 PT 站点运行状态页（病危 / 站庆 / 死亡 / 恢复公告），
/// App 直接读取其页面与历史接口，不经 NAS 后端。
/// 缺字段一律保持「未知 / 未提供」，不臆造数值。
library;

/// 站点运行状态（对应页面卡片上的状态条：运行中 / 抢救中 / 已关站）。
enum MonitorSiteState {
  online('健康'),
  down('病危'),
  offline('已关站'),
  unknown('未知');

  const MonitorSiteState(this.label);

  final String label;

  static MonitorSiteState fromRaw(String? raw) => switch ((raw ?? '').trim().toLowerCase()) {
        'online' || 'on' || 'ok' => MonitorSiteState.online,
        'down' || 'rescue' => MonitorSiteState.down,
        'offline' || 'closed' || 'dead' => MonitorSiteState.offline,
        _ => MonitorSiteState.unknown,
      };

  bool get isAlive => this == MonitorSiteState.online || this == MonitorSiteState.down;
}

/// 站点归属：内站 / 外站（页面的 `data-type`）。
enum MonitorSiteScope {
  internal('内站'),
  external('外站'),
  unknown('未分类');

  const MonitorSiteScope(this.label);

  final String label;

  static MonitorSiteScope fromRaw(String? raw) => switch ((raw ?? '').trim().toLowerCase()) {
        'internal' => MonitorSiteScope.internal,
        'external' => MonitorSiteScope.external,
        _ => MonitorSiteScope.unknown,
      };
}

/// 公告分组：病危 / 恢复 / 站庆 / 死亡。
enum MonitorNoticeKind {
  rescue('病危通知'),
  recover('恢复公告'),
  anniversary('站庆预告'),
  dead('死亡讣告'),
  unknown('公告');

  const MonitorNoticeKind(this.label);

  final String label;

  /// 由页面上的分组标题（如「站庆预告：」）推断分组。
  static MonitorNoticeKind fromLabel(String raw) {
    final String label = raw.replaceAll('：', '').replaceAll(':', '').trim();
    if (label.contains('病危') || label.contains('抢救')) return MonitorNoticeKind.rescue;
    if (label.contains('恢复')) return MonitorNoticeKind.recover;
    if (label.contains('站庆')) return MonitorNoticeKind.anniversary;
    if (label.contains('死亡') || label.contains('讣告')) return MonitorNoticeKind.dead;
    return MonitorNoticeKind.unknown;
  }
}

/// 公告里的单条站点记录。
class MonitorNoticeItem {
  const MonitorNoticeItem({
    required this.name,
    required this.url,
    this.note = '',
    this.tooltip = '',
  });

  final String name;
  final String url;

  /// 紧跟站点名后的说明，例如「已抢救 192 小时，濒临死亡」「还有 2 天站庆」。
  final String note;

  /// 站点名链接上的 title 属性，例如「站庆日期：2 天」「最后正常时间：…」。
  final String tooltip;

  String get host => Uri.tryParse(url)?.host ?? url;

  String get displayNote => note.trim();

  /// 是否今天站庆（页面用「今天站庆！」表达）。
  bool get isTodayAnniversary => note.contains('今天') || tooltip.contains('今天');
}

/// 一组公告（同一分组下的多条站点记录）。
class MonitorNoticeGroup {
  const MonitorNoticeGroup({
    required this.kind,
    required this.items,
    this.intro = '',
  });

  final MonitorNoticeKind kind;
  final List<MonitorNoticeItem> items;

  /// 分组前的引导语，例如「监测到站点异常，正在全力抢救中：」。
  final String intro;

  bool get isEmpty => items.isEmpty;

  factory MonitorNoticeGroup.fromJson(Map<String, dynamic> json) => MonitorNoticeGroup(
        kind: MonitorNoticeKind.values.firstWhere(
          (MonitorNoticeKind k) => k.name == json['kind']?.toString(),
          orElse: () => MonitorNoticeKind.unknown,
        ),
        intro: json['intro']?.toString() ?? '',
        items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(
              (Map<String, dynamic> i) => MonitorNoticeItem(
                name: i['name']?.toString() ?? '',
                url: i['url']?.toString() ?? '',
                note: i['note']?.toString() ?? '',
                tooltip: i['tooltip']?.toString() ?? '',
              ),
            )
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'intro': intro,
        'items': items
            .map((MonitorNoticeItem i) => <String, dynamic>{
                  'name': i.name,
                  'url': i.url,
                  'note': i.note,
                  'tooltip': i.tooltip,
                })
            .toList(growable: false),
      };
}

/// 监护页里的一个站点卡片。
class MonitorSiteCard {
  const MonitorSiteCard({
    required this.name,
    required this.url,
    this.state = MonitorSiteState.unknown,
    this.scope = MonitorSiteScope.unknown,
    this.year,
    this.openDate = '',
    this.closeDate = '',
    this.aliveDays,
    this.anniversaryCountdownDays,
    this.deadDays,
    this.iconUrl = '',
    this.searchKey = '',
    this.anniversaryRecent = false,
  });

  final String name;
  final String url;
  final MonitorSiteState state;
  final MonitorSiteScope scope;

  /// 开站年份（页面按年份分组）。
  final int? year;

  /// 开站日期 / 关站日期（页面原样给出，可能为「未知」）。
  final String openDate;
  final String closeDate;

  /// 存活天数。
  final int? aliveDays;

  /// 距下次站庆的天数（页面口径：站庆倒计时，今天站庆为 0）。
  final int? anniversaryCountdownDays;

  /// 已关站天数（死亡天数）。
  final int? deadDays;

  final String iconUrl;

  /// 页面用于站内搜索匹配的关键词（中英文别名）。
  final String searchKey;

  /// 页面标记的「近期站庆」。
  final bool anniversaryRecent;

  String get host => Uri.tryParse(url)?.host ?? url;

  /// 站点身份键：去掉协议、`www.` 与末尾斜杠的域名，用于与本机站点清单匹配。
  String get identityKey {
    String host = this.host.toLowerCase();
    if (host.startsWith('www.')) host = host.substring(4);
    return host;
  }

  bool get isTodayAnniversary => anniversaryCountdownDays == 0;

  /// 「站庆 X 天」文本；无数据时为空。
  String get anniversaryLabel =>
      anniversaryCountdownDays == null ? '' : '站庆 $anniversaryCountdownDays 天';

  /// 「存活 X 天」文本；无数据时为空。
  String get aliveLabel => aliveDays == null ? '' : '存活 $aliveDays 天';

  /// 「已死亡 X 天」文本；无数据时为空。
  String get deadLabel => deadDays == null ? '' : '已死亡 $deadDays 天';

  String get periodLabel {
    final List<String> parts = <String>[
      if (openDate.isNotEmpty && openDate != '未知') '开站 $openDate',
      if (closeDate.isNotEmpty && closeDate != '未知') '关站 $closeDate',
    ];
    return parts.join(' · ');
  }

  factory MonitorSiteCard.fromJson(Map<String, dynamic> json) => MonitorSiteCard(
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        state: MonitorSiteState.fromRaw(json['state']?.toString()),
        scope: MonitorSiteScope.fromRaw(json['scope']?.toString()),
        year: (json['year'] as num?)?.toInt(),
        openDate: json['openDate']?.toString() ?? '',
        closeDate: json['closeDate']?.toString() ?? '',
        aliveDays: (json['aliveDays'] as num?)?.toInt(),
        anniversaryCountdownDays: (json['anniversaryCountdownDays'] as num?)?.toInt(),
        deadDays: (json['deadDays'] as num?)?.toInt(),
        iconUrl: json['iconUrl']?.toString() ?? '',
        searchKey: json['searchKey']?.toString() ?? '',
        anniversaryRecent: json['anniversaryRecent'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'url': url,
        'state': state.name,
        'scope': scope.name,
        'year': year,
        'openDate': openDate,
        'closeDate': closeDate,
        'aliveDays': aliveDays,
        'anniversaryCountdownDays': anniversaryCountdownDays,
        'deadDays': deadDays,
        'iconUrl': iconUrl,
        'searchKey': searchKey,
        'anniversaryRecent': anniversaryRecent,
      };
}

/// 顶部统计（与页面侧栏口径一致，由 App 本地汇总）。
class MonitorTotals {
  const MonitorTotals({
    this.total = 0,
    this.online = 0,
    this.down = 0,
    this.offline = 0,
    this.anniversaryToday = 0,
  });

  final int total;
  final int online;
  final int down;
  final int offline;
  final int anniversaryToday;

  static MonitorTotals fromSites(List<MonitorSiteCard> sites) {
    int online = 0;
    int down = 0;
    int offline = 0;
    int anniversaryToday = 0;
    for (final MonitorSiteCard site in sites) {
      switch (site.state) {
        case MonitorSiteState.online:
          online++;
        case MonitorSiteState.down:
          down++;
        case MonitorSiteState.offline:
          offline++;
        case MonitorSiteState.unknown:
          break;
      }
      // 已关站站点不再计算站庆（与页面脚本口径一致）。
      if (site.state != MonitorSiteState.offline && site.isTodayAnniversary) anniversaryToday++;
    }
    return MonitorTotals(
      total: sites.length,
      online: online,
      down: down,
      offline: offline,
      anniversaryToday: anniversaryToday,
    );
  }
}

/// 一次监护室快照。
class MonitorDashboard {
  const MonitorDashboard({
    required this.sites,
    required this.notices,
    this.fetchedAt,
    this.fromCache = false,
    this.sourceUrl = '',
    this.notice = '',
  });

  final List<MonitorSiteCard> sites;
  final List<MonitorNoticeGroup> notices;
  final DateTime? fetchedAt;

  /// 是否来自本地缓存（网络不可用时的降级展示，界面必须标注）。
  final bool fromCache;
  final String sourceUrl;
  final String notice;

  MonitorTotals get totals => MonitorTotals.fromSites(sites);

  bool get isEmpty => sites.isEmpty && notices.isEmpty;

  /// 指定分组的公告（无则返回空分组，便于界面直接渲染）。
  MonitorNoticeGroup groupOf(MonitorNoticeKind kind) => notices.firstWhere(
        (MonitorNoticeGroup g) => g.kind == kind,
        orElse: () => MonitorNoticeGroup(kind: kind, items: const <MonitorNoticeItem>[]),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fetchedAt': fetchedAt?.toIso8601String(),
        'sourceUrl': sourceUrl,
        'sites': sites.map((MonitorSiteCard s) => s.toJson()).toList(growable: false),
        'notices': notices.map((MonitorNoticeGroup g) => g.toJson()).toList(growable: false),
      };

  factory MonitorDashboard.fromJson(Map<String, dynamic> json) => MonitorDashboard(
        sites: (json['sites'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(MonitorSiteCard.fromJson)
            .toList(growable: false),
        notices: (json['notices'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(MonitorNoticeGroup.fromJson)
            .toList(growable: false),
        fetchedAt: DateTime.tryParse(json['fetchedAt']?.toString() ?? ''),
        fromCache: true,
        sourceUrl: json['sourceUrl']?.toString() ?? '',
      );
}

/// 历史事件（死亡 / 站庆），来自监护室的公开历史接口。
class MonitorHistoryEvent {
  const MonitorHistoryEvent({
    required this.name,
    required this.date,
    this.label = '',
    this.description = '',
    this.url = '',
  });

  final String name;
  final String date;
  final String label;
  final String description;
  final String url;

  static MonitorHistoryEvent fromJson(Map<String, dynamic> json) => MonitorHistoryEvent(
        name: json['name']?.toString() ?? '',
        date: json['date']?.toString() ?? '',
        label: json['event_label']?.toString() ?? json['label']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
      );
}

/// 历史事件分页。
class MonitorHistoryPage {
  const MonitorHistoryPage({
    this.items = const <MonitorHistoryEvent>[],
    this.nextPage,
    this.hasMore = false,
  });

  final List<MonitorHistoryEvent> items;
  final int? nextPage;
  final bool hasMore;
}