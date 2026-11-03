import '../models/status_models.dart';
import 'app_keys.dart';
import 'prefs_store.dart';

/// 12 大站点槽位仓库（需求 11：主页显示 12 大站点收集进度）。
///
/// 站点清单由用户自行配置：应用只维护 12 个槽位及其关联的已添加站点，
/// 收集进度由槽位是否已关联站点 + 该站点的养老进度共同决定。
class MajorSiteRepository {
  MajorSiteRepository({required this.prefs});

  final PrefsStore prefs;

  static const int storageVersion = 1;
  static const int slotCount = 12;

  /// 读取槽位；未配置时返回 12 个空槽。
  List<MajorSiteSlot> loadAll() {
    final Map<String, dynamic>? raw = prefs.getJson(PrefKeys.majorSites);
    if (raw == null) return MajorSiteSlot.defaults(count: slotCount);
    final Object? list = raw['slots'];
    if (list is! List) return MajorSiteSlot.defaults(count: slotCount);

    final List<MajorSiteSlot> slots = list
        .whereType<Map<String, dynamic>>()
        .map(MajorSiteSlot.fromJson)
        .where((MajorSiteSlot s) => s.slot > 0)
        .toList()
      ..sort((MajorSiteSlot a, MajorSiteSlot b) => a.slot.compareTo(b.slot));
    if (slots.isEmpty) return MajorSiteSlot.defaults(count: slotCount);
    return slots;
  }

  Future<void> saveAll(List<MajorSiteSlot> slots) {
    final List<MajorSiteSlot> sorted = slots.toList()
      ..sort((MajorSiteSlot a, MajorSiteSlot b) => a.slot.compareTo(b.slot));
    return prefs.setJson(PrefKeys.majorSites, <String, dynamic>{
      'version': storageVersion,
      'slots': sorted.map((MajorSiteSlot s) => s.toJson()).toList(growable: false),
    });
  }

  Future<void> upsert(MajorSiteSlot slot) async {
    final List<MajorSiteSlot> slots = loadAll().toList();
    final int index = slots.indexWhere((MajorSiteSlot s) => s.slot == slot.slot);
    if (index >= 0) {
      slots[index] = slot;
    } else {
      slots.add(slot);
    }
    await saveAll(slots);
  }

  /// 已配置的槽位数（收集进度分子）。
  int configuredCount(List<MajorSiteSlot> slots) =>
      slots.where((MajorSiteSlot s) => s.isConfigured).length;

  /// 收集进度（已配置槽位 / 总槽位）。
  double collectionProgress(List<MajorSiteSlot> slots) =>
      slots.isEmpty ? 0 : configuredCount(slots) / slots.length;
}