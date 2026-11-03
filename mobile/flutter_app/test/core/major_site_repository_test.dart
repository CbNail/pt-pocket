// 12 大站点槽位仓库测试：默认空槽、写入覆盖、持久化与收集进度口径。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/status_models.dart';
import 'package:pt_pocket/core/storage/major_site_repository.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late MajorSiteRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    repo = MajorSiteRepository(prefs: PrefsStore(await SharedPreferences.getInstance()));
  });

  test('未配置时返回 12 个空槽，收集进度为 0', () {
    final List<MajorSiteSlot> slots = repo.loadAll();

    expect(slots, hasLength(12));
    expect(slots.first.slot, 1);
    expect(slots.last.slot, 12);
    expect(slots.every((MajorSiteSlot s) => !s.isConfigured), isTrue);
    expect(repo.configuredCount(slots), 0);
    expect(repo.collectionProgress(slots), 0);
  });

  test('写入槽位后落盘，同名槽位是覆盖而不是追加', () async {
    await repo.upsert(const MajorSiteSlot(slot: 3, name: '站点三', siteId: 's3'));
    await repo.upsert(const MajorSiteSlot(slot: 3, name: '站点三（改名）', siteId: 's3'));

    final List<MajorSiteSlot> slots = repo.loadAll();
    expect(slots, hasLength(12));
    expect(slots[2].name, '站点三（改名）');
    expect(slots[2].siteId, 's3');
    expect(slots[2].isConfigured, isTrue);
    expect(repo.configuredCount(slots), 1);
    expect(repo.collectionProgress(slots), closeTo(1 / 12, 1e-9));
  });

  test('重建仓库后配置仍然保留（升级不丢配置）', () async {
    await repo.upsert(const MajorSiteSlot(slot: 1, name: '站点一', siteId: 's1'));
    await repo.upsert(const MajorSiteSlot(slot: 2, name: '站点二', siteId: 's2'));

    final MajorSiteRepository reopened =
        MajorSiteRepository(prefs: PrefsStore(await SharedPreferences.getInstance()));
    final List<MajorSiteSlot> slots = reopened.loadAll();

    expect(reopened.configuredCount(slots), 2);
    expect(reopened.collectionProgress(slots), closeTo(2 / 12, 1e-9));
  });

  test('数据损坏时回退为空槽而不抛异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'ptp.major.sites': 'not-json'});
    final MajorSiteRepository broken =
        MajorSiteRepository(prefs: PrefsStore(await SharedPreferences.getInstance()));

    expect(broken.loadAll(), hasLength(12));
    expect(broken.configuredCount(broken.loadAll()), 0);
  });
}