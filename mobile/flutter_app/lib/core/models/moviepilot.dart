/// MoviePilot 实例、搜索结果与搜索请求模型。
///
/// 约定：站点与 MoviePilot 的协议调用统一在 NAS 后端完成（规格书 §7.1），
/// 移动端只提交搜索请求、展示归一化结果并下发推送参数。
library;

import '../network/endpoint_resolver.dart' show ActiveLink;
import '../network/url_utils.dart';
import 'service_health.dart';

/// MoviePilot 适配版本。
///
/// 需求 4：先按 v2 打通，v3 出正式版后再补适配层。
enum MpVersion {
  v2('v2', '已打通：搜索、资源详情与推送参数映射'),
  v3('v3', '适配层已预留：等 MoviePilot v3 正式版发布后补齐实现');

  const MpVersion(this.label, this.description);

  final String label;
  final String description;

  static MpVersion fromName(String? value) => values.firstWhere(
        (MpVersion v) => v.name == value,
        orElse: () => MpVersion.v2,
      );
}

/// MoviePilot 实例配置（非机密；API 令牌在安全存储）。
///
/// 地址支持内网与外网两条通道（[lanBaseUrl] / [wanBaseUrl]），与 NAS 服务地址一致：
/// 内网优先、失败回退外网，回到家庭网络后自动切回。
/// [baseUrl] 仅作为兼容旧数据的“单一地址”字段保留。
class MpInstance {
  const MpInstance({
    required this.id,
    required this.name,
    this.baseUrl = '',
    this.lanBaseUrl = '',
    this.wanBaseUrl = '',
    this.version = MpVersion.v2,
    this.credentialConfigured = false,
    this.enabled = true,
    this.searchEnhance = false,
    this.health = ServiceHealth.unknown,
    this.lastTestedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;

  /// 兼容字段：旧数据里的单一地址。
  final String baseUrl;

  /// 内网地址（可空）。
  final String lanBaseUrl;

  /// 外网地址（可空，一般为 lucky 反代入口）。
  final String wanBaseUrl;

  final MpVersion version;
  final bool credentialConfigured;
  final bool enabled;

  /// 是否用于搜索增强（把该实例纳入聚合搜索）。
  final bool searchEnhance;
  final ServiceHealth health;
  final DateTime? lastTestedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Uri? get lanUri => UrlUtils.normalize(lanBaseUrl);
  Uri? get wanUri => UrlUtils.normalize(wanBaseUrl);

  bool get hasLan => lanUri != null;
  bool get hasWan => wanUri != null;

  /// 是否至少配了一个可用地址（含旧数据里的单一地址）。
  bool get hasAnyAddress => hasLan || hasWan || UrlUtils.normalize(baseUrl) != null;

  /// 已配置地址，内网在前；旧数据只有单一地址时用该地址兜底。
  List<String> get addresses => <String>[
        if (hasLan) lanUri!.toString(),
        if (hasWan) wanUri!.toString(),
        if (!hasLan && !hasWan && UrlUtils.normalize(baseUrl) != null)
          UrlUtils.normalize(baseUrl)!.toString(),
      ];

  /// 内网优先的展示地址。
  String get displayAddress => addresses.isEmpty ? '' : addresses.first;

  /// 双通道说明（用于界面展示与交给 NAS 后端）。
  String get addressSummary {
    final List<String> parts = <String>[
      if (hasLan) '内网 ${lanUri!}',
      if (hasWan) '外网 ${wanUri!}',
      if (!hasLan && !hasWan) if (UrlUtils.normalize(baseUrl) != null) '${UrlUtils.normalize(baseUrl)!}',
    ];
    return parts.isEmpty ? '未配置地址' : parts.join(' · ');
  }

  String get host {
    final Uri? uri = lanUri ?? wanUri ?? UrlUtils.normalize(baseUrl);
    return uri?.host ?? baseUrl;
  }

  /// 按当前生效链路取地址；该通道未配置时退回内网优先的地址。
  String addressFor(ActiveLink link) {
    if (link == ActiveLink.lan && hasLan) return lanUri!.toString();
    if (link == ActiveLink.wan && hasWan) return wanUri!.toString();
    return displayAddress;
  }

  MpInstance copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? lanBaseUrl,
    String? wanBaseUrl,
    MpVersion? version,
    bool? credentialConfigured,
    bool? enabled,
    bool? searchEnhance,
    ServiceHealth? health,
    DateTime? lastTestedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      MpInstance(
        id: id ?? this.id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        lanBaseUrl: lanBaseUrl ?? this.lanBaseUrl,
        wanBaseUrl: wanBaseUrl ?? this.wanBaseUrl,
        version: version ?? this.version,
        credentialConfigured: credentialConfigured ?? this.credentialConfigured,
        enabled: enabled ?? this.enabled,
        searchEnhance: searchEnhance ?? this.searchEnhance,
        health: health ?? this.health,
        lastTestedAt: lastTestedAt ?? this.lastTestedAt,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'lanBaseUrl': lanBaseUrl,
        'wanBaseUrl': wanBaseUrl,
        'version': version.name,
        'credentialConfigured': credentialConfigured,
        'enabled': enabled,
        'searchEnhance': searchEnhance,
        'health': health.name,
        'lastTestedAt': lastTestedAt?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  /// 读取实例；旧数据（只有一个 `baseUrl`）按内网/公网自动归到对应通道，不丢用户填过的地址。
  factory MpInstance.fromJson(Map<String, dynamic> json) {
    final String legacy = json['baseUrl'] as String? ?? '';
    String lan = json['lanBaseUrl'] as String? ?? '';
    String wan = json['wanBaseUrl'] as String? ?? '';
    if (lan.isEmpty && wan.isEmpty && legacy.isNotEmpty) {
      final Uri? uri = UrlUtils.normalize(legacy);
      if (uri != null && UrlUtils.isPrivateHost(uri.host)) {
        lan = uri.toString();
      } else {
        wan = uri.toString();
      }
    }
    return MpInstance(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      baseUrl: legacy,
      lanBaseUrl: lan,
      wanBaseUrl: wan,
      version: MpVersion.fromName(json['version'] as String?),
      credentialConfigured: json['credentialConfigured'] as bool? ?? false,
      enabled: json['enabled'] as bool? ?? true,
      searchEnhance: json['searchEnhance'] as bool? ?? false,
      health: ServiceHealth.fromName(json['health'] as String?),
      lastTestedAt: _parseDate(json['lastTestedAt']),
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }
}

/// 促销类型（站点侧标记，颜色之外必须有文字）。
enum PromotionType {
  none('无促销'),
  free('免费'),
  half('50%'),
  twoXFree('2×免费'),
  twoXHalf('2×50%'),
  twoXUp('2×上传'),
  other('其它促销');

  const PromotionType(this.label);

  final String label;

  bool get isPromotion => this != PromotionType.none;

  static PromotionType parse(String? raw) {
    final String value = (raw ?? '').toLowerCase().replaceAll(' ', '').replaceAll('×', 'x');
    if (value.isEmpty || value == 'none' || value == 'normal') return PromotionType.none;
    if (value.contains('2x50') || (value.contains('2x') && value.contains('50'))) {
      return PromotionType.twoXHalf;
    }
    if (value.contains('2xup') || value.contains('2x上传')) return PromotionType.twoXUp;
    if (value.contains('2x') && (value.contains('free') || value.contains('免费'))) {
      return PromotionType.twoXFree;
    }
    if (value.contains('50')) return PromotionType.half;
    if (value.contains('free') || value.contains('免费')) return PromotionType.free;
    return PromotionType.other;
  }
}

/// 搜索范围。
enum SearchScope {
  allSites('全部站点'),
  enabledSites('已启用站点'),
  favorites('已收藏');

  const SearchScope(this.label);

  final String label;
}

/// 促销筛选。
enum PromotionFilter {
  all('全部'),
  free('免费'),
  twoXFree('2×免费'),
  half('50%');

  const PromotionFilter(this.label);

  final String label;
}

/// 排序方式。
enum SortOption {
  relevance('相关度', 'relevance'),
  seeders('做种数', 'seeders'),
  published('发布时间', 'publishedAt'),
  size('大小', 'size');

  const SortOption(this.label, this.apiValue);

  final String label;
  final String apiValue;
}

/// 聚合搜索请求。
class SearchRequest {
  const SearchRequest({
    required this.keyword,
    this.siteIds = const <String>[],
    this.mpInstanceIds = const <String>[],
    this.promotion = PromotionFilter.all,
    this.sort = SortOption.relevance,
    this.page = 1,
    this.pageSize = 50,
  });

  final String keyword;
  final List<String> siteIds;
  final List<String> mpInstanceIds;
  final PromotionFilter promotion;
  final SortOption sort;
  final int page;
  final int pageSize;

  bool get isValid => keyword.trim().isNotEmpty;

  SearchRequest copyWith({
    String? keyword,
    List<String>? siteIds,
    List<String>? mpInstanceIds,
    PromotionFilter? promotion,
    SortOption? sort,
    int? page,
    int? pageSize,
  }) =>
      SearchRequest(
        keyword: keyword ?? this.keyword,
        siteIds: siteIds ?? this.siteIds,
        mpInstanceIds: mpInstanceIds ?? this.mpInstanceIds,
        promotion: promotion ?? this.promotion,
        sort: sort ?? this.sort,
        page: page ?? this.page,
        pageSize: pageSize ?? this.pageSize,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'keyword': keyword.trim(),
        'siteIds': siteIds,
        'mpInstanceIds': mpInstanceIds,
        'promotion': promotion.name,
        'sort': sort.apiValue,
        'page': page,
        'pageSize': pageSize,
      };
}

/// 单条搜索结果（跨站点与 MoviePilot 归一化）。
class SearchResultItem {
  const SearchResultItem({
    required this.id,
    required this.title,
    this.siteId = '',
    this.siteName = '',
    this.subtitle = '',
    this.sizeBytes = 0,
    this.seeders = 0,
    this.leechers = 0,
    this.publishedAt,
    this.promotion = PromotionType.none,
    this.downloadUrl = '',
    this.detailUrl = '',
    this.category = '',
    this.source = 'site',
  });

  final String id;
  final String title;
  final String siteId;
  final String siteName;
  final String subtitle;
  final int sizeBytes;
  final int seeders;
  final int leechers;
  final DateTime? publishedAt;
  final PromotionType promotion;

  /// 服务端下发的下载地址（由 NAS 携带凭据抓取，App 不直接访问站点）。
  final String downloadUrl;
  final String detailUrl;
  final String category;

  /// 来源：`site`（站点搜索）或 `moviepilot`（搜索增强命中）。
  final String source;

  bool get isFromMoviePilot => source == 'moviepilot';

  /// 收藏键：站点 + 资源唯一 id。
  String get favoriteKey => '$siteId:$id';

  SearchResultItem copyWith({PromotionType? promotion}) => SearchResultItem(
        id: id,
        title: title,
        siteId: siteId,
        siteName: siteName,
        subtitle: subtitle,
        sizeBytes: sizeBytes,
        seeders: seeders,
        leechers: leechers,
        publishedAt: publishedAt,
        promotion: promotion ?? this.promotion,
        downloadUrl: downloadUrl,
        detailUrl: detailUrl,
        category: category,
        source: source,
      );

  factory SearchResultItem.fromJson(Map<String, dynamic> json) => SearchResultItem(
        id: json['id']?.toString() ?? json['torrentId']?.toString() ?? '',
        title: json['title']?.toString() ?? json['name']?.toString() ?? '',
        siteId: json['siteId']?.toString() ?? '',
        siteName: json['siteName']?.toString() ?? '',
        subtitle: json['subtitle']?.toString() ?? json['description']?.toString() ?? '',
        sizeBytes: _num(json, <String>['sizeBytes', 'size']).toInt(),
        seeders: _num(json, <String>['seeders', 'seedersCount']).toInt(),
        leechers: _num(json, <String>['leechers', 'leechersCount']).toInt(),
        publishedAt: _date(json['publishedAt'] ?? json['publishTime']),
        promotion: PromotionType.parse(
          json['promotion']?.toString() ?? json['promotionType']?.toString(),
        ),
        downloadUrl: json['downloadUrl']?.toString() ?? '',
        detailUrl: json['detailUrl']?.toString() ?? '',
        category: json['category']?.toString() ?? '',
        source: json['source']?.toString() ?? 'site',
      );
}

/// 一页搜索结果。
class SearchPageResult {
  const SearchPageResult({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasMore,
    this.siteErrors = const <String, String>{},
    this.notice = '',
  });

  final List<SearchResultItem> items;
  final int page;
  final int pageSize;
  final bool hasMore;

  /// 部分站点失败信息（站点名 → 原因），支持"部分成功"展示。
  final Map<String, String> siteErrors;

  /// 服务端附加提示（例如搜索增强的降级说明）。
  final String notice;

  bool get hasSiteErrors => siteErrors.isNotEmpty;

  SearchPageResult copyWith({
    List<SearchResultItem>? items,
    int? page,
    int? pageSize,
    bool? hasMore,
    Map<String, String>? siteErrors,
    String? notice,
  }) =>
      SearchPageResult(
        items: items ?? this.items,
        page: page ?? this.page,
        pageSize: pageSize ?? this.pageSize,
        hasMore: hasMore ?? this.hasMore,
        siteErrors: siteErrors ?? this.siteErrors,
        notice: notice ?? this.notice,
      );

  factory SearchPageResult.fromJson(Map<String, dynamic> json, {required int requestedPage}) {
    final Object? rawItems = json['items'] ?? json['results'];
    final List<SearchResultItem> items = rawItems is List
        ? rawItems
            .whereType<Map<String, dynamic>>()
            .map(SearchResultItem.fromJson)
            .toList(growable: false)
        : const <SearchResultItem>[];

    final Map<String, String> errors = <String, String>{};
    final Object? rawErrors = json['siteErrors'] ?? json['errors'];
    if (rawErrors is Map) {
      rawErrors.forEach((Object? key, Object? value) {
        errors[key?.toString() ?? ''] = value?.toString() ?? '';
      });
    }

    final int page = _num(json, <String>['page']).toInt();
    final int pageSize = _num(json, <String>['pageSize']).toInt();
    return SearchPageResult(
      items: items,
      page: page > 0 ? page : requestedPage,
      pageSize: pageSize > 0 ? pageSize : items.length,
      hasMore: json['hasMore'] as bool? ?? false,
      siteErrors: errors,
      notice: json['notice']?.toString() ?? '',
    );
  }
}

num _num(Map<String, dynamic> json, List<String> keys) {
  for (final String key in keys) {
    final Object? value = json[key];
    if (value is num) return value;
    if (value is String) {
      final num? parsed = num.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value) : null;

DateTime? _parseDate(Object? value) => value is String ? DateTime.tryParse(value) : null;