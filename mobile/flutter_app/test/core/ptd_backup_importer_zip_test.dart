// PTD 备份 zip 导入测试：多成员识别、按站点合并、无关成员如实标注为已忽略。
//
// PTD 插件导出的是一个 zip（config.json / cookies.json / userInfo.json /
// manifest.json / downloadHistory.json ...），站点信息分散在多个成员里，
// 导入时应由 App 自行挑出要用的成员，而不是要求用户手动选文件。

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/services/ptd_backup_importer.dart';

/// 组装一个与 PTD 导出结构相近的 zip 备份。
Uint8List _buildZip(Map<String, String> members) {
  final Archive archive = Archive();
  members.forEach((String name, String content) {
    archive.addFile(ArchiveFile.string(name, content));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _ptdZip() => _buildZip(<String, String>{
      'manifest.json': jsonEncode(<String, dynamic>{
        'app': 'PT-depiler',
        'version': '0.2.3',
        'exportedAt': '2026-11-04T10:32:00Z',
      }),
      'config.json': jsonEncode(<String, dynamic>{
        'sites': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'mteam',
            'name': 'M-Team',
            'baseUrl': 'https://m-team.example',
            'apiKey': 'KEY-1',
          },
          <String, dynamic>{
            'id': 'chdbits',
            'name': 'CHDBits',
            'url': 'chdbits.example',
          },
        ],
      }),
      'cookies.json': jsonEncode(<String, dynamic>{
        'm-team.example': 'sid=abc; tok=def',
        'chdbits.example': 'sid=xyz',
      }),
      'userInfo.json': jsonEncode(<String, dynamic>{
        'm-team.example': <String, dynamic>{
          'passkey': 'PK-1',
          'user': <String, dynamic>{'name': 'me'},
        },
      }),
      'downloadHistory.json': jsonEncode(<String, dynamic>{
        'downloadHistory': <Map<String, dynamic>>[
          <String, dynamic>{'hash': 'abc', 'name': 'Some.Torrent', 'size': 123},
        ],
      }),
    });

void main() {
  const PtdBackupImporter importer = PtdBackupImporter();
  const String mTeamHost = 'm-team.example';

  test('zip 备份：跨成员合并出完整站点，无关成员标注为已忽略', () {
    final PtdImportResult result = importer.parseBytes(_ptdZip());

    expect(result.isZip, isTrue);
    expect(result.entries, hasLength(2));
    expect(result.importableEntries, hasLength(2));

    final PtdImportEntry mTeam =
        result.entries.firstWhere((PtdImportEntry e) => e.baseUrl!.contains(mTeamHost));
    expect(mTeam.name, 'M-Team');
    expect(mTeam.baseUrl, 'https://$mTeamHost');
    // 名称/地址来自 config.json，Cookie 来自 cookies.json，Passkey 来自 userInfo.json
    expect(mTeam.apiKey, 'KEY-1');
    expect(mTeam.cookieString, 'sid=abc; tok=def');
    expect(mTeam.passkey, 'PK-1');
    expect(mTeam.sources, containsAll(<String>['config.json', 'cookies.json', 'userInfo.json']));

    final PtdImportEntry chdbits =
        result.entries.firstWhere((PtdImportEntry e) => e.baseUrl!.contains('chdbits.example'));
    expect(chdbits.name, 'CHDBits');
    expect(chdbits.baseUrl, 'https://chdbits.example');
    expect(chdbits.cookieString, 'sid=xyz');

    // 成员处理情况：采用 3 个，忽略 manifest 与下载历史
    expect(result.usedMembers.map((PtdMemberSummary m) => m.name), containsAll(<String>[
      'config.json',
      'cookies.json',
      'userInfo.json',
    ]));
    final PtdMemberSummary manifest = result.members
        .firstWhere((PtdMemberSummary m) => m.name == 'manifest.json');
    expect(manifest.used, isFalse);
    expect(manifest.note, contains('未识别到站点条目'));
    final PtdMemberSummary history = result.members
        .firstWhere((PtdMemberSummary m) => m.name == 'downloadHistory.json');
    expect(history.used, isFalse);
  });

  test('zip 内子目录成员同样能被识别', () {
    final Uint8List bytes = _buildZip(<String, String>{
      'export/config.json': jsonEncode(<String, dynamic>{
        'sites': <Map<String, dynamic>>[
          <String, dynamic>{'name': '子目录站点', 'baseUrl': 'sub.example'},
        ],
      }),
    });

    final PtdImportResult result = importer.parseBytes(bytes);
    expect(result.entries, hasLength(1));
    expect(result.entries.first.name, '子目录站点');
    expect(result.entries.first.baseUrl, 'https://sub.example');
  });

  test('cookies.json 只有域名与 Cookie 串时也能建出站点条目', () {
    final Uint8List bytes = _buildZip(<String, String>{
      'cookies.json': jsonEncode(<String, dynamic>{'only.example': 'sid=1'}),
    });

    final PtdImportResult result = importer.parseBytes(bytes);
    expect(result.entries, hasLength(1));
    expect(result.entries.first.name, 'only.example');
    expect(result.entries.first.baseUrl, 'https://only.example');
    expect(result.entries.first.cookieString, 'sid=1');
    expect(result.entries.first.importable, isTrue);
  });

  test('parseBytes 也能处理误选的单个 JSON 文件', () {
    final Uint8List bytes = Uint8List.fromList(
      utf8.encode('{"sites":[{"name":"单文件站点","baseUrl":"one.example"}]}'),
    );

    final PtdImportResult result = importer.parseBytes(bytes);
    expect(result.isZip, isFalse);
    expect(result.entries, hasLength(1));
    expect(result.entries.first.name, '单文件站点');
  });

  test('既不是 zip 也不是 UTF-8 文本时给出明确提示', () {
    final PtdImportResult result = importer.parseBytes(Uint8List.fromList(<int>[0xFF, 0xFE, 0x00]));

    expect(result.entries, isEmpty);
    expect(result.warnings.single, contains('既不是 zip 包，也不是 UTF-8 文本'));
  });

  test('损坏的 zip 不会抛异常，而是返回提示', () {
    final PtdImportResult result =
        importer.parseZipBytes(Uint8List.fromList(<int>[0x50, 0x4B, 0x03, 0x04, 0x00]));

    expect(result.entries, isEmpty);
    expect(result.warnings, isNotEmpty);
  });
}