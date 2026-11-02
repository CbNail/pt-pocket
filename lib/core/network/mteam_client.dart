import 'package:dio/dio.dart';

class MTeamConfig {
  const MTeamConfig({required this.apiKey});
  final String apiKey;
}

class MTeamNotConfigured implements Exception {
  @override
  String toString() => '未配置 M-Team API Key（请到「站点管理」填写）';
}

class MTeamTorrent {
  const MTeamTorrent({
    required this.id,
    required this.name,
    this.subtitle,
    this.sizeBytes,
    this.seeders,
    this.leechers,
    this.snatches,
    this.isFree = false,
    this.createdText,
  });

  factory MTeamTorrent.fromJson(Map<String, dynamic> j) {
    // 新版 API 把做种/下载数/促销放在嵌套 status 对象里；兼容旧版顶层字段
    Map<String, dynamic> st = const {};
    final rawStatus = j['status'];
    if (rawStatus is Map) st = rawStatus.cast<String, dynamic>();

    String pick(Map<String, dynamic> m, String k) =>
        m[k] == null ? '' : '${m[k]}';

    final discount = pick(st, 'discount').isNotEmpty
        ? pick(st, 'discount')
        : pick(j, 'discount');
    final seeders = num.tryParse(pick(st, 'seeders').isNotEmpty
        ? pick(st, 'seeders')
        : pick(j, 'seeders'));
    final leechers = num.tryParse(pick(st, 'leechers').isNotEmpty
        ? pick(st, 'leechers')
        : pick(j, 'leechers'));
    String sn = pick(st, 'snatches');
    if (sn.isEmpty) sn = pick(j, 'snatches');
    if (sn.isEmpty) sn = pick(j, 'finished');

    // FREE / 2X_FREE 等均视为免费下载
    final free = discount.toUpperCase().contains('FREE');

    return MTeamTorrent(
      id: pick(j, 'id'),
      name: pick(j, 'name'),
      subtitle: j['smallDescr']?.toString(),
      sizeBytes: num.tryParse(pick(j, 'size')),
      seeders: seeders,
      leechers: leechers,
      snatches: num.tryParse(sn),
      isFree: free,
      createdText: j['createdDate']?.toString(),
    );
  }

  final String id;
  final String name;
  final String? subtitle;
  final num? sizeBytes;
  final num? seeders;
  final num? leechers;
  final num? snatches;
  final bool isFree;
  final String? createdText;

  String get sizeText {
    final b = sizeBytes;
    if (b == null || b <= 0) return '-';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    double v = b.toDouble();
    int u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
  }
}

class MTeamClient {
  MTeamClient._(this._dio);
  final Dio _dio;

  static const storageKey = 'mteam.apikey';
  static const _base = 'https://api.m-team.cc';

  factory MTeamClient.build(MTeamConfig cfg) {
    final dio = Dio(BaseOptions(
      baseUrl: _base,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.headers['x-api-key'] = cfg.apiKey;
        options.headers['User-Agent'] = 'PTPocket/0.4';
        handler.next(options);
      },
    ));
    return MTeamClient._(dio);
  }

  /// 关键词搜索种子（官方为 JSON 请求体，响应 code=="0" 为成功）
  Future<List<MTeamTorrent>> search(String keyword) async {
    final r = await _dio.post(
      '/api/torrent/search',
      data: {'mode': 'normal', 'keyword': keyword, 'page': 1, 'size': 50},
    );
    if (r.data is! Map) {
      var raw = r.data.toString();
      if (raw.length > 200) raw = raw.substring(0, 200);
      throw Exception('M-Team 返回了非预期格式: $raw');
    }
    final body = (r.data as Map).cast<String, dynamic>();
    final code = '${body['code'] ?? ''}'; // code 是字符串 "0"
    final message = '${body['message'] ?? body['msg'] ?? ''}';
    if (code != '0') {
      var raw = r.data.toString();
      if (raw.length > 200) raw = raw.substring(0, 200);
      throw Exception('M-Team 返回错误 code=$code message=$message 原始: $raw');
    }
    final data = (body['data'] as Map?)?.cast<String, dynamic>();
    final node = data?['data'];
    List items;
    if (node is List) {
      items = node; // 新版：data.data 直接是数组
    } else if (node is Map) {
      items = ((node as Map).cast<String, dynamic>())['list'] as List? ??
          const []; // 旧版：data.data.list
    } else {
      items = const [];
    }
    return items
        .whereType<Map>()
        .map((e) => MTeamTorrent.fromJson(e.cast<String, dynamic>()))
        .toList();
  }
}
