// 站点直连（NexusPHP 结构）解析测试（需求 2 / 3 / 4）：
// - 用户页：用户名 / 等级 / 上传下载 / 分享率（含 ∞）/ 魔力 / 做种 / 邀请 / 邮件 / H&R / 注册时间；
// - 缺失字段记入 missing，界面据此显示「数据未提供」；
// - 搜索页：种子行解析（id / 标题 / 大小 / 做种下载 / 促销 / 分类 / 下载地址带 passkey）；
// - 空结果页与「结构不认识」页的区分；
// - 登录页识别与凭据取值。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/direct/nexusphp_client.dart';
import 'package:pt_pocket/core/models/moviepilot.dart';

const String _userPage = '''
<html><body>
<table><tr><td class="rowhead">欢迎</td><td>
<a href="userdetails.php?id=20740">CBNail</a></td></tr></table>
<table>
  <tr><td>等级</td><td>Elite User</td></tr>
  <tr><td>上传量</td><td><font color="green">1.234 TB</font></td></tr>
  <tr><td>下载量</td><td>41.11 GB</td></tr>
  <tr><td>分享率</td><td>30.74</td></tr>
  <tr><td>魔力值</td><td>86895.0</td></tr>
  <tr><td>做种中</td><td>310</td></tr>
  <tr><td>下载中</td><td>4</td></tr>
  <tr><td>邀请</td><td>1 (0)</td></tr>
  <tr><td>未读消息</td><td>2</td></tr>
  <tr><td>H&amp;R</td><td>0/0/15</td></tr>
  <tr><td>注册时间</td><td>2026-07-25 09:56:42</td></tr>
</table>
</body></html>
''';

const String _loginPage = '''
<html><body><form method="post" action="takelogin.php">
<input type="text" name="username"><input type="password" name="password">
</form></body></html>
''';

const String _searchPage = '''
<html><body>
<table id="torrenttable">
  <tr><td class="colhead">类型</td><td class="colhead">标题</td></tr>
  <tr>
    <td class="rowfollow"><a href="torrents.php?cat=401"><img src="pic/cat401.gif" title="电影"></a></td>
    <td class="rowfollow"><a href="details.php?id=12345&hit=1" title="仙逆 第01集 2160p">仙逆 第01集</a></td>
    <td class="rowfollow" align="center">2026-11-01 12:00:00</td>
    <td class="rowfollow" align="center">1.23 GB</td>
    <td class="rowfollow" align="center"><a href="peers.php?id=12345&type=seeder">12</a></td>
    <td class="rowfollow" align="center"><a href="peers.php?id=12345&type=leecher">3</a></td>
    <td class="rowfollow" align="center"><a href="details.php?id=12345">免费</a></td>
  </tr>
  <tr>
    <td class="rowfollow"><a href="torrents.php?cat=404"><img src="pic/cat404.gif" title="剧集"></a></td>
    <td class="rowfollow"><a href="details.php?id=67890&hit=1">某剧 S01E01 1080p</a></td>
    <td class="rowfollow" align="center">2026-10-31 08:30:00</td>
    <td class="rowfollow" align="center">5.5 GB</td>
    <td class="rowfollow" align="center"><a href="peers.php?id=67890&type=seeder">0</a></td>
    <td class="rowfollow" align="center"><a href="peers.php?id=67890&type=leecher">1</a></td>
    <td class="rowfollow" align="center"><img class="pro_2up" src="pic/2up.gif" alt="2x"></td>
  </tr>
</table>
</body></html>
''';

void main() {
  group('用户页解析', () {
    test('基本字段与用户名、uid', () {
      final SiteUserSnapshot snapshot = NexusPhpUserParser.parse(
        _userPage,
        siteId: 'site-1',
        siteName: '测试站',
        now: DateTime(2026, 11, 4),
      );
      expect(snapshot.username, 'CBNail');
      expect(snapshot.userId, '20740');
      expect(snapshot.userClass, 'Elite User');
      expect(snapshot.uploadedBytes, (1.234 * (1 << 40)).round(), reason: '1.234 TB 按 1024 进制');
      expect(snapshot.downloadedBytes, (41.11 * (1 << 30)).round());
      expect(snapshot.ratio, 30.74);
      expect(snapshot.bonus, 86895);
      expect(snapshot.seedingCount, 310);
      expect(snapshot.leechingCount, 4);
      expect(snapshot.invites, 1);
      expect(snapshot.unreadMessages, 2);
      expect(snapshot.hrCount, 0);
      expect(snapshot.hrSummary, '0/0/15');
      expect(snapshot.joinDate, DateTime(2026, 7, 25, 9, 56, 42));
      expect(snapshot.missing, isEmpty);
      expect(snapshot.hasCoreNumbers, isTrue);
      expect(snapshot.ratioLabel, '30.74');
    });

    test('分享率 ∞ 与缺失字段的处理', () {
      final SiteUserSnapshot snapshot = NexusPhpUserParser.parse(
        '<html><body><a href="userdetails.php?id=1">who</a>分享率: ∞</body></html>',
        siteId: 's',
        siteName: '某站',
      );
      expect(snapshot.infiniteRatio, isTrue);
      expect(snapshot.ratioLabel, '∞');
      expect(snapshot.missing, contains('上传量'));
      expect(snapshot.missing, contains('注册时间'));
      expect(snapshot.hasCoreNumbers, isFalse, reason: '没有任何数值时不应写入本地采样');
    });

    test('登录页识别', () {
      expect(NexusPhpUserParser.looksLikeLoginPage(_loginPage), isTrue);
      expect(NexusPhpUserParser.looksLikeLoginPage(_userPage), isFalse);
    });

    test('凭据取值：Cookie 与 Passkey', () {
      final Map<String, dynamic> credential = <String, dynamic>{
        'type': 'passkey',
        'passkey': 'ABCDEF',
        'cookie': 'c_secure_pass=abc',
      };
      expect(NexusPhpClient.cookieOf(credential), 'c_secure_pass=abc');
      expect(NexusPhpClient.passkeyOf(credential, 'x'), 'ABCDEF');
      expect(NexusPhpClient.cookieOf(null), '');
      expect(
        NexusPhpClient.passkeyOf(<String, dynamic>{'cookie': 'a=1; passkey=ZZZ99'},
            'a=1; passkey=ZZZ99'),
        'ZZZ99',
        reason: 'Passkey 也可能只存在于 Cookie 串里',
      );
    });

    test('字节换算', () {
      expect(NexusPhpUserParser.bytesFrom('1', 'TB'), 1 << 40);
      expect(NexusPhpUserParser.bytesFrom('2.5', 'GiB'), (2.5 * (1 << 30)).round());
      expect(NexusPhpUserParser.bytesFrom('700', 'K'), 700 * 1024);
      expect(NexusPhpUserParser.bytesFrom('', 'GB'), isNull);
    });
  });

  group('搜索页解析', () {
    test('结果行解析（含促销与 passkey 下载地址）', () {
      final SearchPageResult result = NexusPhpSearchParser.parse(
        _searchPage,
        siteId: 'site-1',
        siteName: '测试站',
        baseUrl: 'https://test.example',
        page: 1,
        pageSize: 50,
        passkey: 'PASS123',
      );
      expect(result.items.length, 2);

      final SearchResultItem first = result.items.first;
      expect(first.id, '12345');
      expect(first.title, '仙逆 第01集 2160p', reason: '优先用链接 title 属性');
      expect(first.siteName, '测试站');
      expect(first.sizeBytes, (1.23 * (1 << 30)).round());
      expect(first.seeders, 12);
      expect(first.leechers, 3);
      expect(first.promotion, PromotionType.free);
      expect(first.category, isNotNull);
      expect(first.publishedAt, DateTime(2026, 11, 1, 12, 0, 0));
      expect(first.downloadUrl, 'https://test.example/download.php?id=12345&passkey=PASS123');
      expect(first.detailUrl, 'https://test.example/details.php?id=12345');
      expect(first.source, 'site');

      final SearchResultItem second = result.items[1];
      expect(second.id, '67890');
      expect(second.title, '某剧 S01E01 1080p');
      expect(second.sizeBytes, (5.5 * (1 << 30)).round());
      expect(second.seeders, 0);
      expect(second.leechers, 1);
      expect(second.promotion, PromotionType.twoXUp);
      expect(result.hasMore, isFalse);
    });

    test('促销筛选：免费只保留免费', () {
      final SearchPageResult result = NexusPhpSearchParser.parse(
        _searchPage,
        siteId: 's',
        siteName: '站',
        baseUrl: 'https://test.example',
        page: 1,
        pageSize: 50,
        promotion: PromotionFilter.free,
      );
      expect(result.items.length, 1);
      expect(result.items.single.promotion, PromotionType.free);
    });

    test('空结果页不报错，结构不认识的页明确报错', () {
      final SearchPageResult empty = NexusPhpSearchParser.parse(
        '<html><body><table id="torrenttable"><tr><td>没有找到任何种子</td></tr></table></body></html>',
        siteId: 's',
        siteName: '站',
        baseUrl: 'https://test.example',
        page: 1,
        pageSize: 50,
      );
      expect(empty.items, isEmpty);
      expect(empty.hasMore, isFalse);

      expect(
        () => NexusPhpSearchParser.parse(
          '<html><body><h1>Cloudflare 502</h1></body></html>',
          siteId: 's',
          siteName: '站',
          baseUrl: 'https://test.example',
          page: 1,
          pageSize: 50,
        ),
        throwsA(
          isA<SiteFetchException>().having(
            (SiteFetchException e) => e.kind,
            'kind',
            SiteFetchFailureKind.unparsed,
          ),
        ),
      );
    });
  });
}