import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../network/url_utils.dart';

/// PTD / PT-depiler 备份中的一条站点记录（宽松解析结果）。
class PtdImportEntry {
  const PtdImportEntry({
    required this.name,
    this.baseUrl,
    this.cookieString,
    this.apiKey,
    this.passkey,
    this.notes = const <String>[],
    this.sources = const <String>[],
  });

  final String name;
  final String? baseUrl;
  final String? cookieString;
  final String? apiKey;
  final String? passkey;

  /// 该条目解析过程中的提示（缺字段、字段不识别等）。
  final List<String> notes;

  /// 本条数据来自备份里的哪些成员（如 config.json / cookies.json）。
  final List<String> sources;

  bool get importable => baseUrl != null && baseUrl!.isNotEmpty;

  bool get hasCredential =>
      (cookieString?.isNotEmpty ?? false) ||
      (apiKey?.isNotEmpty ?? false) ||
      (passkey?.isNotEmpty ?? false);
}

/// 备份里一个成员（zip 内的单个文件）的处理结果。
///
/// 导入时不要求用户自己挑文件：App 逐个成员尝试解析，只采用能识别出站点信息的成员，
/// 其余成员如实列出「已忽略」与原因，不做静默丢弃。
class PtdMemberSummary {
  const PtdMemberSummary({
    required this.name,
    required this.used,
    required this.records,
    this.note = '',
  });

  /// 成员名（zip 内的路径）。
  final String name;

  /// 是否被本次导入采用。
  final bool used;

  /// 从该成员识别出的记录条数。
  final int records;

  /// 采用/忽略的原因。
  final String note;

  String get label {
    if (used) return '已采用 · $records 条';
    return note.isEmpty ? '已忽略' : '已忽略 · $note';
  }
}

/// 备份解析结果。
class PtdImportResult {
  const PtdImportResult({
    required this.entries,
    required this.warnings,
    this.members = const <PtdMemberSummary>[],
    this.isZip = false,
  });

  final List<PtdImportEntry> entries;

  /// 整体性提示（结构不识别、部分条目跳过等）。
  final List<String> warnings;

  /// zip 备份内各成员的处理情况；单文件/粘贴导入时为空。
  final List<PtdMemberSummary> members;

  /// 是否来自 zip 备份。
  final bool isZip;

  bool get isEmpty => entries.isEmpty;

  List<PtdImportEntry> get importableEntries =>
      entries.where((PtdImportEntry e) => e.importable).toList(growable: false);

  List<PtdMemberSummary> get usedMembers =>
      members.where((PtdMemberSummary m) => m.used).toList(growable: false);

  List<PtdMemberSummary> get ignoredMembers =>
      members.where((PtdMemberSummary m) => !m.used).toList(growable: false);
}

/// 逐条累积中的站点草稿：不同成员写同一站点时按字段合并，不整条覆盖。
class _Draft {
  _Draft({required this.key});

  final String key;
  String? name;
  String? baseUrl;
  String? cookie;
  String? apiKey;
  String? passkey;
  final List<String> sources = <String>[];
  final List<String> notes = <String>[];

  void absorb(_Draft other, List<String> warnings) {
    if (name == null || name!.isEmpty) name = other.name;
    if (baseUrl == null || baseUrl!.isEmpty) baseUrl = other.baseUrl;
    _mergeField('Cookie', cookie, other.cookie, warnings, (String? v) => cookie = v);
    _mergeField('API Key', apiKey, other.apiKey, warnings, (String? v) => apiKey = v);
    _mergeField('Passkey', passkey, other.passkey, warnings, (String? v) => passkey = v);
    for (final String source in other.sources) {
      if (!sources.contains(source)) sources.add(source);
    }
    for (final String note in other.notes) {
      if (!notes.contains(note)) notes.add(note);
    }
  }

  void _mergeField(
    String label,
    String? current,
    String? incoming,
    List<String> warnings,
    void Function(String?) assign,
  ) {
    if (incoming == null || incoming.isEmpty) return;
    if (current == null || current.isEmpty) {
      assign(incoming);
      return;
    }
    if (current != incoming) {
      warnings.add('「${name ?? key}」的 $label 在多个成员中不一致，保留先解析到的值');
    }
  }

  PtdImportEntry toEntry() => PtdImportEntry(
        name: (name == null || name!.isEmpty) ? (baseUrl ?? '未命名站点') : name!,
        baseUrl: baseUrl,
        cookieString: cookie,
        apiKey: apiKey,
        passkey: passkey,
        notes: List<String>.unmodifiable(notes),
        sources: List<String>.unmodifiable(sources),
      );
}

/// 备份导入器：解析 PTD / PT-depiler 导出的 **zip 备份** 或单个 JSON。
///
/// PTD 插件导出的是一个 zip，里面同时有 `config.json`、`cookies.json`、
/// `userInfo.json`、`manifest.json` 等多个成员，站点信息分散在不同成员里。
/// 这里不要求用户自己挑文件，而是：
/// 1. 逐个成员解析，能识别出站点记录的成员才参与导入（[PtdMemberSummary]）；
/// 2. 同一站点在不同成员里的字段（名称 / 地址 / Cookie / API Key / Passkey）按字段合并；
/// 3. 识别不出的成员如实标注「已忽略」与原因，不静默丢弃。
///
/// 结构会随插件版本演进，解析按「字段别名宽松匹配」处理。
class PtdBackupImporter {
  const PtdBackupImporter();

  static const List<String> _collectionKeys = <String>[
    'sites',
    'data',
    'backup',
    'entries',
    'items',
    'list',
    'siteList',
    'siteConfig',
    'siteConfigs',
    'siteConfigMap',
  ];

  static const List<String> _nameKeys = <String>[
    'name',
    'siteName',
    'site_name',
    'title',
    'label',
    'nickname',
    'id',
  ];

  static const List<String> _urlKeys = <String>[
    'baseUrl',
    'base_url',
    'url',
    'host',
    'domain',
    'siteUrl',
    'site_url',
    'homepage',
    'homePage',
  ];

  static const List<String> _cookieKeys = <String>[
    'cookie',
    'cookies',
    'cookieString',
    'cookie_string',
    'cookieHeader',
    'cookieStr',
  ];

  static const List<String> _apiKeyKeys = <String>['apiKey', 'api_key', 'apikey', 'key', 'token'];
  static const List<String> _passkeyKeys = <String>['passkey', 'passKey', 'pass_key'];

  static final RegExp _hostKeyPattern =
      RegExp(r'^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,24}$', caseSensitive: false);
  static final RegExp _ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  /// 解析粘贴的单个 JSON 备份。
  PtdImportResult parse(String jsonText) {
    final String text = jsonText.trim();
    if (text.isEmpty) {
      return const PtdImportResult(entries: <PtdImportEntry>[], warnings: <String>['未提供备份内容']);
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      return PtdImportResult(
        entries: const <PtdImportEntry>[],
        warnings: <String>['备份内容不是合法 JSON：${error.message}'],
      );
    }

    final List<Map<String, dynamic>> records = _recordsFromJson(decoded);
    if (records.isEmpty) {
      return const PtdImportResult(
        entries: <PtdImportEntry>[],
        warnings: <String>['未在备份中识别到站点条目，请确认导出内容与本应用支持的格式一致'],
      );
    }

    final List<String> warnings = <String>[];
    final Map<String, _Draft> drafts = <String, _Draft>{};
    for (final Map<String, dynamic> record in records) {
      final _Draft? draft = _toDraft(record, '粘贴的 JSON', warnings);
      if (draft == null) continue;
      final _Draft? existing = drafts[draft.key];
      if (existing == null) {
        drafts[draft.key] = draft;
      } else {
        existing.absorb(draft, warnings);
      }
    }
    return _finish(drafts, warnings, const <PtdMemberSummary>[], isZip: false);
  }

  /// 解析 PTD 插件导出的 zip（或误选的单个 JSON 文件，按内容自动识别）。
  PtdImportResult parseBytes(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      return parseZipBytes(bytes);
    }
    final String? text = _tryDecodeUtf8(bytes);
    if (text == null) {
      return const PtdImportResult(
        entries: <PtdImportEntry>[],
        warnings: <String>['备份既不是 zip 包，也不是 UTF-8 文本，无法解析'],
      );
    }
    return parse(text);
  }

  /// 解析 zip 备份的字节内容。
  PtdImportResult parseZipBytes(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      return PtdImportResult(
        entries: const <PtdImportEntry>[],
        warnings: <String>['备份不是可解析的 zip 包：$error'],
      );
    }

    final List<String> warnings = <String>[];
    final Map<String, _Draft> drafts = <String, _Draft>{};
    final List<PtdMemberSummary> members = <PtdMemberSummary>[];

    for (final ArchiveFile file in archive.files) {
      if (!file.isFile) continue;
      final String path = file.name;
      final String base = _baseName(path);
      if (!base.toLowerCase().endsWith('.json')) {
        members.add(PtdMemberSummary(name: path, used: false, records: 0, note: '非 JSON 成员'));
        continue;
      }

      final String? text = _tryDecodeUtf8(file.content);
      if (text == null) {
        members.add(PtdMemberSummary(name: path, used: false, records: 0, note: '不是 UTF-8 文本'));
        continue;
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException catch (error) {
        members.add(
          PtdMemberSummary(name: path, used: false, records: 0, note: 'JSON 解析失败：${error.message}'),
        );
        continue;
      }

      final List<Map<String, dynamic>> records = _recordsFromJson(decoded);
      bool used = false;
      for (final Map<String, dynamic> record in records) {
        final _Draft? draft = _toDraft(record, base, warnings);
        if (draft == null) continue;
        used = true;
        final _Draft? existing = drafts[draft.key];
        if (existing == null) {
          drafts[draft.key] = draft;
        } else {
          existing.absorb(draft, warnings);
        }
      }
      members.add(
        PtdMemberSummary(
          name: path,
          used: used,
          records: records.length,
          note: used ? '' : (records.isEmpty ? '未识别到站点条目' : '记录缺少站点名与地址'),
        ),
      );
    }

    if (members.isEmpty) {
      warnings.add('zip 包内没有可读取的成员');
    }
    return _finish(drafts, warnings, members, isZip: true);
  }

  PtdImportResult _finish(
    Map<String, _Draft> drafts,
    List<String> warnings,
    List<PtdMemberSummary> members, {
    required bool isZip,
  }) {
    final List<PtdImportEntry> entries =
        drafts.values.map((_Draft d) => d.toEntry()).toList(growable: false);
    for (final PtdImportEntry entry in entries) {
      if (!entry.importable) {
        warnings.add('「${entry.name}」缺少站点地址，已跳过');
      }
    }
    if (entries.isEmpty) {
      warnings.add('未在备份中识别到站点条目，请确认导出内容与本应用支持的格式一致');
    } else if (entries.every((PtdImportEntry e) => !e.importable)) {
      warnings.add('所有条目都缺少可用的站点地址，无法直接导入');
    }
    return PtdImportResult(
      entries: entries,
      warnings: warnings,
      members: members,
      isZip: isZip,
    );
  }

  // ------------------------------------------------------------ 结构识别

  List<Map<String, dynamic>> _recordsFromJson(Object? decoded) {
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    if (decoded is! Map) return const <Map<String, dynamic>>[];

    // 1) 已知集合键：值为数组，或值为「映射的映射」。
    for (final String key in _collectionKeys) {
      final Object? value = decoded[key];
      if (value is List) {
        final List<Map<String, dynamic>> records =
            value.whereType<Map<String, dynamic>>().toList(growable: false);
        if (records.isNotEmpty) return records;
      }
      if (value is Map) {
        final List<Map<String, dynamic>> records = _mapOfMaps(Map<String, dynamic>.from(value));
        if (records.isNotEmpty) return records;
      }
    }

    // 2) 顶层映射：形如 { "域名或站点 id": {...} }。
    final List<Map<String, dynamic>> mapped = <Map<String, dynamic>>[];
    decoded.forEach((Object? key, Object? value) {
      if (key is! String || value is! Map) return;
      final Map<String, dynamic> record = Map<String, dynamic>.from(value);
      final bool siteLike = _looksLikeHostKey(key) ||
          _hasAny(record, _urlKeys) ||
          _hasAny(record, _nameKeys) ||
          _hasAny(record, _cookieKeys) ||
          _hasAny(record, _apiKeyKeys) ||
          _hasAny(record, _passkeyKeys);
      if (siteLike) mapped.add(_withKeyFallback(key, record));
    });
    if (mapped.isNotEmpty) return mapped;

    // 3) 域名字典：整段映射的键都像域名时，值按 Cookie 字符串处理
    //    （如 cookies.json 的 { "站点域名": "sid=1; tok=2" }）。
    if (decoded.isNotEmpty &&
        decoded.keys.every((Object? k) => k is String && _looksLikeHostKey(k))) {
      return decoded.entries.map((MapEntry<Object?, Object?> e) {
        final String domain = e.key as String;
        final Object? value = e.value;
        if (value is Map) {
          return _withKeyFallback(domain, Map<String, dynamic>.from(value));
        }
        return <String, dynamic>{
          'name': domain,
          'baseUrl': domain,
          'cookie': value?.toString() ?? '',
        };
      }).toList(growable: false);
    }

    return const <Map<String, dynamic>>[];
  }

  List<Map<String, dynamic>> _mapOfMaps(Map<String, dynamic> source) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    source.forEach((String key, Object? value) {
      if (value is Map) {
        out.add(_withKeyFallback(key, Map<String, dynamic>.from(value)));
      }
    });
    return out;
  }

  static Map<String, dynamic> _withKeyFallback(String key, Map<String, dynamic> value) =>
      <String, dynamic>{
        if (!_hasAny(value, _nameKeys)) 'name': key,
        if (!_hasAny(value, _urlKeys)) 'baseUrl': key,
        ...value,
      };

  static bool _hasAny(Map<String, dynamic> record, List<String> keys) =>
      keys.any((String key) => record[key] != null);

  /// 键是否像域名或 IP（用于区分「域名字典」与普通配置里的元数据键）。
  static bool _looksLikeHostKey(String key) {
    final String k = key.trim().toLowerCase();
    if (k.isEmpty || k.contains(' ') || k.contains('/')) return false;
    if (k == 'localhost') return true;
    if (_ipv4Pattern.hasMatch(k)) return true;
    if (!k.contains('.')) return false;
    return _hostKeyPattern.hasMatch(k);
  }

  static String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

  static String? _tryDecodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  // ------------------------------------------------------------ 字段映射

  _Draft? _toDraft(Map<String, dynamic> record, String memberName, List<String> warnings) {
    final String? rawUrl = _firstString(record, _urlKeys);
    final String? rawName = _firstString(record, _nameKeys);
    final String? baseUrl = UrlUtils.normalize(rawUrl)?.toString();
    final List<String> notes = <String>[];
    final String? cookie = _cookieValue(record, notes);
    final String? apiKey = _firstString(record, _apiKeyKeys);
    final String? passkey = _firstString(record, _passkeyKeys);

    if (baseUrl == null && (rawName == null || rawName.isEmpty) && cookie == null) {
      // 与站点无关的记录（版本号、时间戳等），静默跳过而不是伪造站点。
      return null;
    }
    if (rawUrl != null && baseUrl == null) {
      warnings.add('地址「$rawUrl」无法解析，已跳过');
      return null;
    }

    final String? host = baseUrl == null ? null : Uri.tryParse(baseUrl)?.host;
    final String key = host != null && host.isNotEmpty
        ? 'host:${host.toLowerCase()}'
        : 'name:${(rawName ?? '').toLowerCase()}';

    final _Draft draft = _Draft(key: key)
      ..baseUrl = baseUrl
      ..cookie = cookie
      ..apiKey = apiKey
      ..passkey = passkey
      ..name = (rawName != null && rawName.isNotEmpty) ? rawName : host;
    draft.notes.addAll(notes);
    draft.sources.add(memberName);
    return draft;
  }

  /// Cookie 可能是字符串、`[{name, value}]` 数组，或 `{name: value}` 映射。
  String? _cookieValue(Map<String, dynamic> record, List<String> notes) {
    for (final String key in _cookieKeys) {
      final Object? value = record[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is List) {
        final String joined = value
            .whereType<Map<String, dynamic>>()
            .map((Map<String, dynamic> item) {
              final Object? name = item['name'];
              if (name is! String || name.isEmpty) return '';
              return '$name=${item['value'] ?? ''}';
            })
            .where((String pair) => pair.isNotEmpty)
            .join('; ');
        if (joined.isNotEmpty) return joined;
        notes.add('字段 $key 中没有可用的 Cookie');
      }
      if (value is Map) {
        final String joined = value.entries
            .where((MapEntry<Object?, Object?> e) => e.key is String)
            .map((MapEntry<Object?, Object?> e) => '${e.key}=${e.value ?? ''}')
            .join('; ');
        if (joined.isNotEmpty) return joined;
      }
    }
    return null;
  }

  String? _firstString(Map<String, dynamic> record, List<String> keys) {
    for (final String key in keys) {
      final Object? value = record[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return value.toString();
    }
    return null;
  }
}