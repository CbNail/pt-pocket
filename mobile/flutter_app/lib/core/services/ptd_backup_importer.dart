import 'dart:convert';

/// PTD / PT-depiler 备份中的一条站点记录（宽松解析结果）。
class PtdImportEntry {
  const PtdImportEntry({
    required this.name,
    this.baseUrl,
    this.cookieString,
    this.apiKey,
    this.passkey,
    this.notes = const <String>[],
  });

  final String name;
  final String? baseUrl;
  final String? cookieString;
  final String? apiKey;
  final String? passkey;

  /// 该条目解析过程中的提示（缺字段、字段不识别等）。
  final List<String> notes;

  bool get importable => baseUrl != null && baseUrl!.isNotEmpty;

  bool get hasCredential =>
      (cookieString?.isNotEmpty ?? false) ||
      (apiKey?.isNotEmpty ?? false) ||
      (passkey?.isNotEmpty ?? false);
}

/// 备份解析结果。
class PtdImportResult {
  const PtdImportResult({required this.entries, required this.warnings});

  final List<PtdImportEntry> entries;

  /// 整体性提示（结构不识别、部分条目跳过等）。
  final List<String> warnings;

  bool get isEmpty => entries.isEmpty;

  List<PtdImportEntry> get importableEntries =>
      entries.where((PtdImportEntry e) => e.importable).toList(growable: false);
}

/// 备份导入器：解析 PTD / PT-depiler 导出的 JSON 备份。
///
/// 说明：备份结构会随版本演进，这里按「字段别名宽松匹配」解析，
/// 不识别的内容不会静默丢弃，而是写进 [PtdImportResult.warnings] 供用户核对。
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
  ];

  static const List<String> _nameKeys = <String>['name', 'siteName', 'site_name', 'title', 'label', 'id'];
  static const List<String> _urlKeys = <String>['baseUrl', 'base_url', 'url', 'host', 'domain', 'siteUrl', 'site_url', 'homepage'];
  static const List<String> _cookieKeys = <String>['cookie', 'cookies', 'cookieString', 'cookie_string', 'cookieHeader'];
  static const List<String> _apiKeyKeys = <String>['apiKey', 'api_key', 'apikey', 'key', 'token'];
  static const List<String> _passkeyKeys = <String>['passkey', 'passKey', 'pass_key'];

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

    final List<Map<String, dynamic>> records = _collectRecords(decoded);
    if (records.isEmpty) {
      return const PtdImportResult(
        entries: <PtdImportEntry>[],
        warnings: <String>['未在备份中识别到站点条目，请确认导出内容与本应用支持的格式一致'],
      );
    }

    final List<PtdImportEntry> entries = <PtdImportEntry>[];
    final List<String> warnings = <String>[];
    for (final Map<String, dynamic> record in records) {
      entries.add(_toEntry(record, warnings));
    }
    if (entries.every((PtdImportEntry e) => !e.importable)) {
      warnings.add('所有条目都缺少可用的站点地址，无法直接导入');
    }
    return PtdImportResult(entries: entries, warnings: warnings);
  }

  List<Map<String, dynamic>> _collectRecords(Object? decoded) {
    if (decoded is List) {
      return decoded.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    if (decoded is Map<String, dynamic>) {
      for (final String key in _collectionKeys) {
        final Object? value = decoded[key];
        if (value is List) {
          return value.whereType<Map<String, dynamic>>().toList(growable: false);
        }
      }
      // 形如 { "站点域名": {...} } 的映射式备份：键作为名称与地址兜底。
      final List<Map<String, dynamic>> mapped = decoded.entries
          .where((MapEntry<String, dynamic> e) => e.value is Map<String, dynamic>)
          .map((MapEntry<String, dynamic> e) {
        final Map<String, dynamic> value = e.value as Map<String, dynamic>;
        return <String, dynamic>{
          if (!_hasAny(value, _nameKeys)) 'name': e.key,
          if (!_hasAny(value, _urlKeys)) 'baseUrl': e.key,
          ...value,
        };
      }).toList(growable: false);
      return mapped;
    }
    return const <Map<String, dynamic>>[];
  }

  static bool _hasAny(Map<String, dynamic> record, List<String> keys) =>
      keys.any((String key) => record[key] != null);

  PtdImportEntry _toEntry(Map<String, dynamic> record, List<String> warnings) {
    final List<String> notes = <String>[];
    final String name = _firstString(record, _nameKeys) ?? '';
    final String? rawUrl = _firstString(record, _urlKeys);
    final String? baseUrl = _normalizeUrl(rawUrl);
    if (rawUrl != null && baseUrl == null) {
      notes.add('地址「$rawUrl」无法解析');
    }

    final String? cookieString = _cookieValue(record, notes);
    final String? apiKey = _firstString(record, _apiKeyKeys);
    final String? passkey = _firstString(record, _passkeyKeys);

    if (name.isEmpty) notes.add('缺少站点名称');
    if (baseUrl == null) notes.add('缺少站点地址');
    final PtdImportEntry entry = PtdImportEntry(
      name: name.isEmpty ? (baseUrl ?? '未命名站点') : name,
      baseUrl: baseUrl,
      cookieString: cookieString,
      apiKey: apiKey,
      passkey: passkey,
      notes: notes,
    );
    if (!entry.importable) {
      warnings.add('「${entry.name}」缺少站点地址，已跳过');
    }
    return entry;
  }

  /// Cookie 可能是字符串，也可能是 `[{name, value}]` 数组。
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

  /// 宽松规范化站点地址：缺协议补 `https://`，并去掉路径、查询与锚点。
  static String? _normalizeUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final String value = raw.trim();
    final Uri? uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return uri.origin;
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null).toString();
  }
}