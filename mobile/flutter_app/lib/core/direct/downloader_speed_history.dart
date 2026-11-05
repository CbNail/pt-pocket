import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一次速率采样。
class DownloaderSpeedSample {
  const DownloaderSpeedSample({required this.at, required this.download, required this.upload});

  final DateTime at;
  final int download;
  final int upload;
}

/// 下载器速率的**内存采样环**（只在本次运行期间有效，不落盘、不做长期统计）。
///
/// 为什么需要它：网格图的速率曲线必须有时间序列。直连 WebUI 只给「当前速率」，
/// 因此每次刷新时把当时的值记一点，采样不足两点时界面显示「采样中」而不是画一条假曲线。
class DownloaderSpeedHistory {
  DownloaderSpeedHistory({this.capacity = 60});

  final int capacity;

  final Map<String, List<DownloaderSpeedSample>> _samples =
      <String, List<DownloaderSpeedSample>>{};

  /// 记一次采样；连续重复值也会记录（曲线才有时间维度）。
  void record(String downloaderId, int download, int upload, {DateTime? now}) {
    final List<DownloaderSpeedSample> list =
        _samples.putIfAbsent(downloaderId, () => <DownloaderSpeedSample>[]);
    list.add(DownloaderSpeedSample(
      at: now ?? DateTime.now(),
      download: download < 0 ? 0 : download,
      upload: upload < 0 ? 0 : upload,
    ));
    if (list.length > capacity) {
      list.removeRange(0, list.length - capacity);
    }
  }

  List<DownloaderSpeedSample> of(String downloaderId) =>
      List<DownloaderSpeedSample>.unmodifiable(
        _samples[downloaderId] ?? const <DownloaderSpeedSample>[],
      );

  void clear(String downloaderId) => _samples.remove(downloaderId);
}

/// 速率采样环（单例，随 ProviderScope 存活）。
final Provider<DownloaderSpeedHistory> downloaderSpeedHistoryProvider =
    Provider<DownloaderSpeedHistory>((Ref ref) => DownloaderSpeedHistory());