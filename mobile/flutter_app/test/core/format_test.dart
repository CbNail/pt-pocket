// 展示格式化测试：字节、速率、剩余时间与百分比口径。

import 'package:flutter_test/flutter_test.dart';
import 'package:pt_pocket/core/utils/format.dart';

void main() {
  test('字节格式化按 1024 进制并保留一位小数', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(-1), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1024 * 1024), '1.0 MB');
    expect(formatBytes(1024 * 1024 * 1024 * 3), '3.0 GB');
  });

  test('速率格式化', () {
    expect(formatSpeed(0), '—');
    expect(formatSpeed(-5), '—');
    expect(formatSpeed(1536), '1.5 KB/s');
  });

  test('剩余时间格式化：未知与不限单独表达', () {
    expect(formatEta(-1), '—');
    expect(formatEta(0), '—');
    expect(formatEta(59), '59s');
    expect(formatEta(90), '1m');
    expect(formatEta(3660), '1h 1m');
    expect(formatEta(8640000), '不限');
  });

  test('百分比格式化并做 0–100 收敛', () {
    expect(formatPercent(0), '0.0%');
    expect(formatPercent(0.5), '50.0%');
    expect(formatPercent(1), '100.0%');
    expect(formatPercent(1.5), '100.0%');
  });
}