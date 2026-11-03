// 站点仓库测试：清单读写、按 id 覆盖、凭据安全存储、坏数据容错。

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/pt_site.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:pt_pocket/core/storage/site_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SiteRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    repo = SiteRepository(
      prefs: PrefsStore(await SharedPreferences.getInstance()),
      secure: SecureStore(),
    );
  });

  test('新增站点写入清单并可读回，时间戳自动补齐', () async {
    await repo.upsert(
      const PtSite(id: 's1', name: '示例站', baseUrl: 'https://a.example'),
    );

    final List<PtSite> loaded = repo.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.id, 's1');
    expect(loaded.first.name, '示例站');
    expect(loaded.first.host, 'a.example');
    expect(loaded.first.framework, SiteFramework.nexusphp);
    expect(loaded.first.authType, SiteAuthType.cookie);
    expect(loaded.first.createdAt, isNotNull);
    expect(loaded.first.updatedAt, isNotNull);
  });

  test('同 id 再次写入是覆盖而不是追加', () async {
    await repo.upsert(const PtSite(id: 's1', name: '示例站', baseUrl: 'https://a.example'));
    await repo.upsert(
      const PtSite(
        id: 's1',
        name: '示例站（改名）',
        baseUrl: 'https://a.example',
        framework: SiteFramework.unit3d,
        authType: SiteAuthType.apiKey,
        favorite: true,
      ),
    );

    final List<PtSite> loaded = repo.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.name, '示例站（改名）');
    expect(loaded.first.framework, SiteFramework.unit3d);
    expect(loaded.first.authType, SiteAuthType.apiKey);
    expect(loaded.first.favorite, isTrue);
  });

  test('凭据写入安全存储，删除站点时一并清理', () async {
    await repo.upsert(const PtSite(id: 's1', name: '示例站', baseUrl: 'https://a.example'));
    await repo.saveCredential('s1', <String, dynamic>{'type': 'cookie', 'cookie': 'a=b; c=d'});

    expect(await repo.hasCredential('s1'), isTrue);
    final Map<String, dynamic>? credential = await repo.readCredential('s1');
    expect(credential?['cookie'], 'a=b; c=d');

    await repo.remove('s1');
    expect(repo.loadAll(), isEmpty);
    expect(await repo.hasCredential('s1'), isFalse);
  });

  test('清单内容损坏时返回空列表而不抛出异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'ptp.sites.index': '{broken'});
    final SiteRepository broken = SiteRepository(
      prefs: PrefsStore(await SharedPreferences.getInstance()),
      secure: SecureStore(),
    );

    expect(broken.loadAll(), isEmpty);
  });
}