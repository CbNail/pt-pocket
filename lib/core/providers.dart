import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pt_pocket/core/network/guardian_client.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';

/// 从安全存储读取 Guardian 配置（null = 未配置）
final guardianConfigProvider = FutureProvider<GuardianConfig?>((ref) async {
  final url = await SecureStore.read(SecureStore.guardianUrl);
  final token = await SecureStore.read(SecureStore.guardianToken);
  if (url == null || token == null || url.isEmpty || token.isEmpty) {
    return null;
  }
  return GuardianConfig(url: url, token: token);
});

/// Guardian 监测状态
final guardianStatusProvider = FutureProvider<List<GuardianSite>>((ref) async {
  final cfg = await ref.watch(guardianConfigProvider.future);
  if (cfg == null) throw GuardianNotConfigured();
  return GuardianClient.build(cfg).fetchStatus();
});
