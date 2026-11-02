import 'package:dio/dio.dart';

class MTeamConfig {
  const MTeamConfig({required this.apiKey});
  final String apiKey;
}

class MTeamNotConfigured implements Exception {
  @override
  String toString() => '未配置 M-Team API Key（请到「设置」页填写）';
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
    bool free = false;
    final f = j['free'];
    if (f == true) free = true;
    if (f is Map) {
      final down = (f['downpercent'] as num?) ?? 0;
      if (down >= 100) free = true;
    }
    final d = j['discount'];
    if (d is String && d.toUpperCase().contains('FREE')) free = true;

    return MTeamTorrent(
      id: '${j['id'] ?? ''}',
      name: '${j['name'] ?? ''}',
      subtitle: j['smallDescr']?.toString(),
      sizeBytes: num.tryParse('${j['size']}'),
      seeders: num.tryParse('${j['seeders']}'),
      leechers: num.tryParse('${j['leechers']}'),
      snatches: num.tryParse('${j['snatches'] ?? j['finished'] ?? ''}'),
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
        options.headers['User-Agent'] = 'PTPocket/0.3';
        handler.next(options);
      },
    ));
    return MTeamClient._(dio);
  }

  /// 关键词搜索种子
  Future<List<MTeamTorrent>> search(String keyword) async {
    final r = await _dio.post(
      '/api/torrent/search',
      data: 'mode=normal&keyword=${Uri.encodeQueryComponent(keyword)}',
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final body = (r.data as Map).cast<String, dynamic>();
    if (body['msg'] != 'SUCCESS') {
      throw Exception('M-Team 接口返回异常：${body['msg']}');
    }
    final data = (body['data'] as Map?)?.cast<String, dynamic>();
    final inner = (data?['data'] as Map?)?.cast<String, dynamic>();
    final list = (inner?['list'] as List?) ?? const [];
    return list
        .map((e) => MTeamTorrent.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }
}
