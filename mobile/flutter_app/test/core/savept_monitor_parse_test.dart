// 监护室直连数据源解析测试（需求 1）：
// - 站点卡片：状态 / 内站外站 / 存活与站庆天数 / 开站关站日期 / 图标 / 年份；
// - 公告分组：病危 / 恢复 / 站庆 / 死亡，逐条保留说明与 title；
// - 顶部统计：床位 / 健康 / 抢救 / 死亡 / 今日站庆（与页面脚本同一口径）；
// - 历史事件接口：`{items, next_page, has_more}` 解析。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/direct/savept_monitor_client.dart';
import 'package:pt_pocket/core/models/monitor_dashboard.dart';

const String _fixture = '''
<html><body>
<div class="filter-toolbar"><label>搜索</label></div>
<div class="announcement-container">
  <div class="alert-banner">
    <div class="alert-content">
      <strong> 病危通知： </strong>
      监测到站点异常，正在全力抢救中：
      <a href="https://lst.gg/" class="site-tag" title="最后正常时间：2026-11-04 22:13:24"> LST </a>
      已抢救0小时 |
      <a href="https://zrpt.example/" class="site-tag" title="最后正常时间：2026-10-20 10:00:00"> ZRPT </a>
      已抢救406小时，濒临死亡
    </div>
  </div>
  <div class="alert-banner">
    <div class="alert-content">
      <strong> 恢复公告： </strong>
      <a href="https://zmpt.example/" class="site-tag" title="恢复时间：2026-10-29 12:00:00"> ZMPT </a>
      于 10月29日12点恢复
    </div>
  </div>
  <div class="alert-banner">
    <div class="alert-content">
      <strong> 站庆预告： </strong>
      <a href="https://xingwan.cc/" class="site-tag" title="站庆日期：2 天"> XingWan </a>
      还有 2 天站庆 |
      <a href="https://xingtan.one/" class="site-tag" title="站庆日期：今天站庆！"> XingTan </a>
      今天站庆！
    </div>
  </div>
  <div class="alert-banner">
    <div class="alert-content">
      <strong> 死亡讣告： </strong>
      <a href="https://www.momentpt.top/" class="site-tag" title="关站时间：10月29日"> MomentPT </a>
      于 10月29日 宣告死亡
    </div>
  </div>
</div>
<div class="year-section" data-section-year="2026">
  <div class="year-title">2026 年<span class="year-count-text">(2 个站点)</span></div>
  <div class="grid-container">
    <a href="https://www.colapt.com" class="card-link" data-year="2026" data-status="online"
       data-search="colapt可乐" data-type="internal" data-anniversary="yes">
      <div class="card " data-opentime="2026-10-11" data-closetime="未知">
        <div class="status-strip bg-on" title="运行中"></div>
        <div class="anniversary-badge">站庆 0 天</div>
        <div class="duration-badge">存活 24 天</div>
        <img class="site-icon" src="https://savept.icu/icon/colapt.png" alt="ColaPT">
        <div class="card-title">ColaPT - 可乐</div>
        <div class="card-tip"><span class="card-tip-row">开站日期：2026-10-11</span></div>
      </div>
    </a>
    <a href="https://pt.cdy.pics" class="card-link" data-year="2026" data-status="offline"
       data-search="cdy传道院" data-type="external" data-anniversary="no">
      <div class="card is-closed" data-opentime="2026-03-30" data-closetime="2026-08-17">
        <div class="status-strip bg-closed" title="已关站"></div>
        <div class="anniversary-badge offline-duration-badge">已死亡 79 天</div>
        <div class="duration-badge">存活 140 天</div>
        <img class="site-icon" src="https://savept.icu/icon/cdy.png" alt="CDY">
        <div class="card-title">CDY - 传道院</div>
        <div class="card-tip"><span class="card-tip-row">死亡日期：2026-08-17</span></div>
      </div>
    </a>
  </div>
</div>
<div class="year-section" data-section-year="2025">
  <div class="grid-container">
    <a href="https://zrpt.example/" class="card-link" data-year="2025" data-status="down"
       data-search="zrpt" data-type="internal" data-anniversary="no">
      <div class="card " data-opentime="2025-01-01" data-closetime="未知">
        <div class="status-strip bg-down" title="抢救中"></div>
        <div class="anniversary-badge">站庆 341 天</div>
        <div class="duration-badge">存活 400 天</div>
        <div class="card-title">ZRPT</div>
      </div>
    </a>
  </div>
</div>
</body></html>
''';

void main() {
  group('监护室页面解析', () {
    late MonitorDashboard dashboard;

    setUp(() {
      dashboard = SavePtMonitorClient.parseDashboard(
        _fixture,
        sourceUrl: Uri.parse('https://savept.icu/'),
        now: DateTime(2026, 11, 4, 22, 30),
      );
    });

    test('站点卡片：状态、类型、存活与站庆天数、日期与图标', () {
      expect(dashboard.sites.length, 3);

      final MonitorSiteCard cola = dashboard.sites.first;
      expect(cola.name, 'ColaPT - 可乐');
      expect(cola.url, 'https://www.colapt.com');
      expect(cola.state, MonitorSiteState.online);
      expect(cola.scope, MonitorSiteScope.internal);
      expect(cola.year, 2026);
      expect(cola.aliveDays, 24);
      expect(cola.anniversaryCountdownDays, 0);
      expect(cola.isTodayAnniversary, isTrue);
      expect(cola.anniversaryRecent, isTrue);
      expect(cola.openDate, '2026-10-11');
      expect(cola.iconUrl, 'https://savept.icu/icon/colapt.png');
      expect(cola.identityKey, 'colapt.com', reason: '用于与本机站点清单匹配');

      final MonitorSiteCard cdy = dashboard.sites[1];
      expect(cdy.state, MonitorSiteState.offline);
      expect(cdy.scope, MonitorSiteScope.external);
      expect(cdy.deadDays, 79);
      expect(cdy.anniversaryCountdownDays, isNull, reason: '已关站不再显示站庆倒计时');
      expect(cdy.aliveDays, 140);
      expect(cdy.closeDate, '2026-08-17');

      final MonitorSiteCard zrpt = dashboard.sites[2];
      expect(zrpt.state, MonitorSiteState.down, reason: 'data-status=down 即抢救中');
      expect(zrpt.anniversaryCountdownDays, 341);
    });

    test('公告分组：内容与说明逐条保留', () {
      expect(dashboard.notices.length, 4);

      final MonitorNoticeGroup rescue = dashboard.groupOf(MonitorNoticeKind.rescue);
      expect(rescue.items.length, 2);
      expect(rescue.intro.contains('全力抢救中'), isTrue);
      expect(rescue.items.first.name, 'LST');
      expect(rescue.items.first.tooltip, '最后正常时间：2026-11-04 22:13:24');
      expect(rescue.items.first.note, '已抢救0小时');
      expect(rescue.items[1].name, 'ZRPT');
      expect(rescue.items[1].note.contains('濒临死亡'), isTrue);

      final MonitorNoticeGroup anniversary = dashboard.groupOf(MonitorNoticeKind.anniversary);
      expect(anniversary.items.length, 2);
      expect(anniversary.items.first.note, '还有 2 天站庆');
      expect(anniversary.items[1].isTodayAnniversary, isTrue);

      expect(dashboard.groupOf(MonitorNoticeKind.dead).items.single.name, 'MomentPT');
      expect(dashboard.groupOf(MonitorNoticeKind.recover).items.single.name, 'ZMPT');
      expect(dashboard.groupOf(MonitorNoticeKind.recover).items.single.note, '于 10月29日12点恢复');
    });

    test('顶部统计：由本地汇总，口径与页面脚本一致', () {
      final MonitorTotals totals = dashboard.totals;
      expect(totals.total, 3);
      expect(totals.online, 1);
      expect(totals.down, 1);
      expect(totals.offline, 1);
      expect(totals.anniversaryToday, 1, reason: '只有在线且站庆 0 天的站点计入');
      expect(dashboard.sourceUrl, 'https://savept.icu/');
      expect(dashboard.fromCache, isFalse);
    });

    test('缓存快照可往返序列化', () {
      final MonitorDashboard restored =
          MonitorDashboard.fromJson(dashboard.toJson());
      expect(restored.sites.length, 3);
      expect(restored.notices.length, 4);
      expect(restored.fromCache, isTrue);
      expect(restored.sites.first.anniversaryCountdownDays, 0);
      expect(restored.fetchedAt?.toIso8601String(),
          dashboard.fetchedAt?.toIso8601String());
    });

    test('看不出站点卡片结构时报错（避免把防护页当空数据）', () async {
      expect(
        () => SavePtMonitorClient.parseDashboard('<html><body>forbidden</body></html>'),
        returnsNormally,
        reason: '解析本身不抛异常，由客户端在站点数为 0 时判定为不可识别',
      );
      final MonitorDashboard empty =
          SavePtMonitorClient.parseDashboard('<html><body>forbidden</body></html>');
      expect(empty.sites, isEmpty);
    });
  });

  group('历史事件接口解析', () {
    test('death / anniversary 分页结构', () {
      final MonitorHistoryPage page = SavePtMonitorClient.parseHistoryPage(
        <String, dynamic>{
          'next_page': 2,
          'has_more': true,
          'items': <dynamic>[
            <String, dynamic>{
              'date': '2026-10-29',
              'description': '瞬间',
              'event_label': '意外死亡',
              'name': 'MomentPT',
              'url': 'https://www.momentpt.top/',
            },
          ],
        },
      );
      expect(page.items.length, 1);
      expect(page.items.first.label, '意外死亡');
      expect(page.nextPage, 2);
      expect(page.hasMore, isTrue);
      expect(SavePtMonitorClient.parseHistoryPage(null).items, isEmpty);
    });
  });
}