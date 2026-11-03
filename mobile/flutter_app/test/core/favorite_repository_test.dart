// 收藏仓库测试：新增/取消收藏、键规则、离线渲染信息保留与排序。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/storage/favorite_repository.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late FavoriteRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    repo = FavoriteRepository(prefs: PrefsStore(await SharedPreferences.getInstance()));
  });

  FavoriteItem item(String siteId, String torrentId, String title) => FavoriteItem(
        siteId: siteId,
        torrentId: torrentId,
        title: title,
        siteName: '站点$siteId',
        sizeBytes: 1024,
        addedAt: DateTime.parse('2026-10-01T00:00:00.000Z'),
      );

  test('toggle 交替新增与取消收藏', () async {
    expect(await repo.toggle(item('s1', 't1', '资源一')), isTrue);
    expect(repo.contains('s1:t1'), isTrue);
    expect(repo.loadAll(), hasLength(1));

    expect(await repo.toggle(item('s1', 't1', '资源一')), isFalse);
    expect(repo.contains('s1:t1'), isFalse);
    expect(repo.loadAll(), isEmpty);
  });

  test('最新收藏排在最前，且可单独移除', () async {
    await repo.toggle(item('s1', 't1', '资源一'));
    await repo.toggle(item('s2', 't2', '资源二'));

    expect(repo.keys(), <String>['s2:t2', 's1:t1']);

    await repo.remove('s1:t1');
    expect(repo.keys(), <String>['s2:t2']);
  });

  test('收藏信息落盘后可读回，含站点与大小', () async {
    await repo.toggle(item('s1', 't1', '资源一'));

    final PrefsStore reopened = PrefsStore(await SharedPreferences.getInstance());
    final List<FavoriteItem> loaded = FavoriteRepository(prefs: reopened).loadAll();

    expect(loaded.single.title, '资源一');
    expect(loaded.single.siteId, 's1');
    expect(loaded.single.torrentId, 't1');
    expect(loaded.single.siteName, '站点s1');
    expect(loaded.single.sizeBytes, 1024);
  });

  test('搜索结果与收藏条目的字段映射保持可推送', () {
    const SearchResultItem result = SearchResultItem(
      id: 't1',
      title: '资源一',
      siteId: 's1',
      siteName: '站点一',
      sizeBytes: 2048,
      downloadUrl: 'http://nas.local/dl/1',
    );

    final FavoriteItem favorite = FavoriteItem.fromSearchResult(result);

    expect(favorite.key, 's1:t1');
    expect(favorite.sizeBytes, 2048);

    final SearchResultItem restored = favorite.toSearchResultItem();
    expect(restored.id, 't1');
    expect(restored.siteId, 's1');
    expect(restored.downloadUrl, 'http://nas.local/dl/1');
  });
}