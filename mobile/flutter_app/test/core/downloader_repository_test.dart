// 下载器仓库测试：配置读写、按 id 覆盖、账号密码安全存储、坏数据容错。

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/models/downloader.dart';
import 'package:pt_pocket/core/storage/downloader_repository.dart';
import 'package:pt_pocket/core/storage/prefs_store.dart';
import 'package:pt_pocket/core/storage/secure_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late DownloaderRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    repo = DownloaderRepository(
      prefs: PrefsStore(await SharedPreferences.getInstance()),
      secure: SecureStore(),
    );
  });

  test('新增下载器写入清单并可读回，时间戳自动补齐', () async {
    await repo.upsert(
      const DownloaderConfig(
        id: 'd1',
        name: '主力 qB',
        kind: DownloaderKind.qbittorrent,
        baseUrl: 'http://192.168.1.10:8080',
        defaultSavePath: '/downloads/PT',
      ),
    );

    final List<DownloaderConfig> loaded = repo.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.name, '主力 qB');
    expect(loaded.first.kind, DownloaderKind.qbittorrent);
    expect(loaded.first.host, '192.168.1.10');
    expect(loaded.first.defaultSavePath, '/downloads/PT');
    expect(loaded.first.createdAt, isNotNull);
    expect(loaded.first.updatedAt, isNotNull);
  });

  test('同 id 再次写入是覆盖而不是追加', () async {
    await repo.upsert(
      const DownloaderConfig(id: 'd1', name: 'A', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:1'),
    );
    await repo.upsert(
      const DownloaderConfig(
        id: 'd1',
        name: 'B',
        kind: DownloaderKind.transmission,
        baseUrl: 'http://b:2',
        username: 'u',
      ),
    );

    final List<DownloaderConfig> loaded = repo.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.name, 'B');
    expect(loaded.first.kind, DownloaderKind.transmission);
    expect(loaded.first.username, 'u');
  });

  test('账号密码写入安全存储，删除下载器时一并清理', () async {
    await repo.upsert(
      const DownloaderConfig(id: 'd1', name: 'A', kind: DownloaderKind.qbittorrent, baseUrl: 'http://a:1'),
    );
    await repo.saveCredential('d1', <String, dynamic>{'username': 'admin', 'password': 'secret'});

    expect(await repo.hasCredential('d1'), isTrue);
    expect((await repo.readCredential('d1'))?['username'], 'admin');

    await repo.remove('d1');
    expect(repo.loadAll(), isEmpty);
    expect(await repo.hasCredential('d1'), isFalse);
  });

  test('清单内容损坏时返回空列表而不抛出异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{'ptp.downloaders.index': 'not-json'});
    final DownloaderRepository broken = DownloaderRepository(
      prefs: PrefsStore(await SharedPreferences.getInstance()),
      secure: SecureStore(),
    );

    expect(broken.loadAll(), isEmpty);
  });
}