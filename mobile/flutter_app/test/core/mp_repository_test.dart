// MoviePilot 实例仓库测试：配置读写、按 id 覆盖、令牌安全存储与坏数据容错。

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';
import 'package:pt_pocket/core/storage/mp_repository.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late MpRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    repo = MpRepository(
      prefs: PrefsStore(await SharedPreferences.getInstance()),
      secure: SecureStore(),
    );
  });

  test('新增实例写入清单并可读回，时间戳自动补齐', () async {
    await repo.upsert(
      const MpInstance(id: 'm1', name: '主 MP', baseUrl: 'http://192.168.1.10:3000'),
    );

    final List<MpInstance> loaded = repo.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.name, '主 MP');
    expect(loaded.first.version, MpVersion.v2);
    expect(loaded.first.host, '192.168.1.10');
    expect(loaded.first.createdAt, isNotNull);
  });

  test('同 id 再次写入是覆盖而不是追加', () async {
    await repo.upsert(const MpInstance(id: 'm1', name: 'A', baseUrl: 'http://a:1'));
    await repo.upsert(
      const MpInstance(
        id: 'm1',
        name: 'B',
        baseUrl: 'http://b:2',
        version: MpVersion.v3,
        searchEnhance: true,
      ),
    );

    final List<MpInstance> loaded = repo.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.name, 'B');
    expect(loaded.first.version, MpVersion.v3);
    expect(loaded.first.searchEnhance, isTrue);
  });

  test('API 令牌写入安全存储，删除实例时一并清理', () async {
    await repo.upsert(const MpInstance(id: 'm1', name: 'A', baseUrl: 'http://a:1'));
    await repo.saveCredential('m1', <String, dynamic>{'apiToken': 'tk-1'});

    expect(await repo.hasCredential('m1'), isTrue);
    expect((await repo.readCredential('m1'))?['apiToken'], 'tk-1');

    await repo.remove('m1');
    expect(repo.loadAll(), isEmpty);
    expect(await repo.hasCredential('m1'), isFalse);
  });

  test('清单内容损坏时返回空列表而不抛出异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'ptp.moviepilot.index': '{broken'});
    final MpRepository broken = MpRepository(
      prefs: PrefsStore(await SharedPreferences.getInstance()),
      secure: SecureStore(),
    );

    expect(broken.loadAll(), isEmpty);
  });
}