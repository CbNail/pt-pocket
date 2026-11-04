import '../models/moviepilot.dart';
import 'app_keys.dart';
import 'prefs_store.dart';
import 'secure_store.dart';

/// MoviePilot 实例仓库：配置走非敏感偏好存储，API 令牌走本机安全存储。
class MpRepository {
  MpRepository({required this.prefs, required this.secure});

  final PrefsStore prefs;
  final SecureStore secure;

  /// 存储结构版本：2 起实例带内网 / 外网双地址（1 为单一地址）。
  static const int storageVersion = 2;

  List<MpInstance> loadAll() {
    final Map<String, dynamic>? raw = prefs.getJson(PrefKeys.mpIndex);
    if (raw == null) return <MpInstance>[];
    final Object? list = raw['instances'];
    if (list is! List) return <MpInstance>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(MpInstance.fromJson)
        .where((MpInstance i) => i.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> saveAll(List<MpInstance> instances) =>
      prefs.setJson(PrefKeys.mpIndex, <String, dynamic>{
        'version': storageVersion,
        'instances': instances.map((MpInstance i) => i.toJson()).toList(growable: false),
      });

  Future<MpInstance> upsert(MpInstance instance) async {
    final List<MpInstance> list = loadAll().toList();
    final DateTime now = DateTime.now();
    final MpInstance stored = instance.copyWith(
      createdAt: instance.createdAt ?? now,
      updatedAt: now,
    );
    final int index = list.indexWhere((MpInstance i) => i.id == instance.id);
    if (index >= 0) {
      list[index] = stored;
    } else {
      list.add(stored);
    }
    await saveAll(list);
    return stored;
  }

  Future<void> remove(String instanceId) async {
    final List<MpInstance> list =
        loadAll().where((MpInstance i) => i.id != instanceId).toList(growable: false);
    await saveAll(list);
    await deleteCredential(instanceId);
  }

  Future<void> saveCredential(String instanceId, Map<String, dynamic> credential) =>
      secure.writeJson(SecureKeys.moviePilotCredential(instanceId), credential);

  Future<Map<String, dynamic>?> readCredential(String instanceId) =>
      secure.readJson(SecureKeys.moviePilotCredential(instanceId));

  Future<void> deleteCredential(String instanceId) =>
      secure.delete(SecureKeys.moviePilotCredential(instanceId));

  Future<bool> hasCredential(String instanceId) async =>
      await readCredential(instanceId) != null;
}