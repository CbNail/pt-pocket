/// 展示层格式化工具：字节、速率、剩余时间、百分比。
///
/// 统一下载任务等数值的呈现口径，避免各页面各自实现导致口径不一致。
library;

const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/// 字节数转可读文本，例如 `1536` → `1.5 KB`。
String formatBytes(int bytes, {int fractionDigits = 1}) {
  if (bytes <= 0) return '0 B';
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) return '${value.round()} B';
  final int digits = value >= 100 ? 0 : fractionDigits;
  return '${value.toStringAsFixed(digits)} ${_units[unit]}';
}

/// 速率文本，例如 `2.5 MB/s`；非正数显示为 `—`。
String formatSpeed(int bytesPerSecond) =>
    bytesPerSecond <= 0 ? '—' : '${formatBytes(bytesPerSecond)}/s';

/// 剩余时间文本：负数或 0 表示未知，8640000 秒（qBittorrent 的"无限"）显示为"不限"。
String formatEta(int seconds) {
  if (seconds <= 0) return '—';
  if (seconds >= 8640000) return '不限';
  final int hours = seconds ~/ 3600;
  final int minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m';
  return '${seconds}s';
}

/// 进度百分比文本（入参为 0–1 的比例）。
String formatPercent(double ratio, {int fractionDigits = 1}) =>
    '${(ratio * 100).clamp(0, 100).toStringAsFixed(fractionDigits)}%';

/// 整数千分位（魔力、积分等按位读的数字用）。
String formatNumber(int value) {
  final String digits = value.abs().toString();
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return value < 0 ? '-$buffer' : '$buffer';
}

/// 日期文本（站点加入时间等，统一 `YYYY-MM-DD`）。
/// 日期 + 时间（`yyyy-MM-dd HH:mm`），用于「刷新时间」这类需要到分钟的场景。
String formatDateTime(DateTime date) {
  final DateTime local = date.toLocal();
  final String hour = local.hour.toString().padLeft(2, '0');
  final String minute = local.minute.toString().padLeft(2, '0');
  return '${formatDate(local)} $hour:$minute';
}

String formatDate(DateTime date) {
  final DateTime local = date.toLocal();
  final String month = local.month.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}