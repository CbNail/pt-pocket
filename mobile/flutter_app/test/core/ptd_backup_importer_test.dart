// PTD / PT-depiler 备份导入测试：多种备份结构、字段别名、跳过与提示。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/services/ptd_backup_importer.dart';

void main() {
  const PtdBackupImporter importer = PtdBackupImporter();

  test('解析 sites 数组形式并保留 Cookie 凭据', () {
    final PtdImportResult result = importer.parse(
      '{"sites":[{"name":"站点A","baseUrl":"http://a.example","cookie":"sid=1; tok=2"}]}',
    );

    expect(result.entries, hasLength(1));
    expect(result.warnings, isEmpty);
    final PtdImportEntry entry = result.entries.first;
    expect(entry.name, '站点A');
    expect(entry.baseUrl, 'http://a.example');
    expect(entry.cookieString, 'sid=1; tok=2');
    expect(entry.importable, isTrue);
    expect(entry.hasCredential, isTrue);
  });

  test('顶层数组形式与 cookie 数组字段可解析为请求头字符串', () {
    final PtdImportResult result = importer.parse(
      '[{"siteName":"站点B","host":"b.example","cookies":[{"name":"sid","value":"1"},{"name":"tok","value":"2"}]}]',
    );

    expect(result.entries, hasLength(1));
    expect(result.entries.first.name, '站点B');
    expect(result.entries.first.baseUrl, 'https://b.example');
    expect(result.entries.first.cookieString, 'sid=1; tok=2');
  });

  test('映射式备份用键作为站点名', () {
    final PtdImportResult result = importer.parse(
      '{"c.example":{"api_key":"KEY-1"}}',
    );

    expect(result.entries, hasLength(1));
    expect(result.entries.first.name, 'c.example');
    expect(result.entries.first.baseUrl, 'https://c.example');
    expect(result.entries.first.apiKey, 'KEY-1');
  });

  test('非 JSON 内容给出整体提示且不产生条目', () {
    final PtdImportResult result = importer.parse('这不是 JSON');

    expect(result.entries, isEmpty);
    expect(result.warnings, isNotEmpty);
    expect(result.warnings.first, contains('不是合法 JSON'));
  });

  test('缺少地址的条目被标记并跳过，而不是静默丢弃', () {
    final PtdImportResult result = importer.parse(
      '{"sites":[{"name":"无地址站点","cookie":"sid=1"},{"name":"可用站点","baseUrl":"d.example"}]}',
    );

    expect(result.entries, hasLength(2));
    expect(result.importableEntries, hasLength(1));
    expect(result.importableEntries.first.name, '可用站点');
    expect(result.warnings.any((String w) => w.contains('无地址站点')), isTrue);
  });

  test('空内容返回提示', () {
    final PtdImportResult result = importer.parse('   ');
    expect(result.isEmpty, isTrue);
    expect(result.warnings, isNotEmpty);
  });
}