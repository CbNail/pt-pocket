import '../models/moviepilot.dart';
import 'app_keys.dart';
import 'prefs_store.dart';

/// 收藏条目：保存足够的展示信息，使收藏列表在离线时也能渲染。
class FavoriteItem {
  const FavoriteItem({
    required this.siteId,
    required this.torrentId,
    required this.title,
    this.siteName = '',
    this.sizeBytes = 0,
    required this.addedAt,
    this.downloadUrl = '',
  });

  final String siteId;
  final String torrentId;
  final String title;
  final String siteName;
  final int sizeBytes;
  final String downloadUrl;
  final DateTime addedAt;

  String get key => FavoriteRepository.buildKey(siteId, torrentId);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'siteId': siteId,
        'torrentId': torrentId,
        'title': title,
        'siteName': siteName,
        'sizeBytes': sizeBytes,
        'downloadUrl': downloadUrl,
        'addedAt': addedAt.toIso8601String(),
      };

  factory FavoriteItem.fromJson(Map<String, dynamic> json) => FavoriteItem(
        siteId: json['siteId'] as String? ?? '',
        torrentId: json['torrentId'] as String? ?? '',
        title: json['title'] as String? ?? '',
        siteName: json['siteName'] as String? ?? '',
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        downloadUrl: json['downloadUrl'] as String? ?? '',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
      );

  /// 把搜索结果转成收藏条目。
  factory FavoriteItem.fromSearchResult(SearchResultItem item, {DateTime? addedAt}) => FavoriteItem(
        siteId: item.siteId,
        torrentId: item.id,
        title: item.title,
        siteName: item.siteName,
        sizeBytes: item.sizeBytes,
        downloadUrl: item.downloadUrl,
        addedAt: addedAt ?? DateTime.now(),
      );

  /// 还原成可复用的搜索结果形态（用于收藏列表与推送）。
  SearchResultItem toSearchResultItem() => SearchResultItem(
        id: torrentId,
        title: title,
        siteId: siteId,
        siteName: siteName,
        sizeBytes: sizeBytes,
        downloadUrl: downloadUrl,
        subtitle: '来自收藏',
      );
}

/// 收藏仓库（本地，需求 18：结果左滑可"下载和收藏"）。
class FavoriteRepository {
  FavoriteRepository({required this.prefs});

  final PrefsStore prefs;

  static const int storageVersion = 1;

  static String buildKey(String siteId, String torrentId) => '$siteId:$torrentId';

  List<FavoriteItem> loadAll() {
    final Map<String, dynamic>? raw = prefs.getJson(PrefKeys.favorites);
    if (raw == null) return <FavoriteItem>[];
    final Object? list = raw['items'];
    if (list is! List) return <FavoriteItem>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(FavoriteItem.fromJson)
        .toList(growable: false);
  }

  Future<void> saveAll(List<FavoriteItem> items) =>
      prefs.setJson(PrefKeys.favorites, <String, dynamic>{
        'version': storageVersion,
        'items': items.map((FavoriteItem i) => i.toJson()).toList(growable: false),
      });

  bool contains(String key) => loadAll().any((FavoriteItem item) => item.key == key);

  /// 切换收藏状态，返回切换后的状态（true 表示已收藏）。
  Future<bool> toggle(FavoriteItem item) async {
    final List<FavoriteItem> items = loadAll().toList();
    final int index = items.indexWhere((FavoriteItem i) => i.key == item.key);
    if (index >= 0) {
      items.removeAt(index);
      await saveAll(items);
      return false;
    }
    items.insert(0, item);
    await saveAll(items);
    return true;
  }

  Future<void> remove(String key) async {
    final List<FavoriteItem> items =
        loadAll().where((FavoriteItem item) => item.key != key).toList(growable: false);
    await saveAll(items);
  }

  /// 收藏的站点 + 资源 id 组合（用于搜索请求的已收藏筛选）。
  List<String> keys() => loadAll().map((FavoriteItem item) => item.key).toList(growable: false);
}