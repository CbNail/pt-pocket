import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 通过系统文件选择器取回的文件内容。
class PickedFileData {
  const PickedFileData({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// 系统文件选择器：Android 侧走本工程 app 模块自带的平台通道。
///
/// 为什么不引第三方插件：在 AGP 9 下 `file_picker` 与 `file_selector_android` 都改成依赖
/// AGP 的**内建 Kotlin**（在 AGP 9 上不再自己 apply Kotlin 插件），而本工程按 Flutter 模板
/// 关闭了内建 Kotlin（`android.gradle.properties` 里的 `android.builtInKotlin=false`），
/// 它们的 Kotlin 源码不会被任何一方编译，构建直接失败：
/// `cannot find symbol: class FilePickerPlugin`。
///
/// 改用 app 模块自己的 MethodChannel 后不依赖任何第三方插件的构建假设——
/// app 模块的 Kotlin 由 Flutter 的 Gradle 插件编译，已经在 CI 上验证可用。
class PlatformFilePicker {
  const PlatformFilePicker({MethodChannel? channel}) : _channel = channel ?? defaultChannel;

  /// 平台通道名（与 `MainActivity` 中注册的一致）。
  static const String channelName = 'ptpocket/file_picker';

  static const MethodChannel defaultChannel = MethodChannel(channelName);

  final MethodChannel _channel;

  /// 默认的备选类型：zip 备份 / json 备份 / 文本，并允许退化为任意文件。
  ///
  /// 选择器只做粗筛；真正的类型判断由 `PtdBackupImporter.parseBytes` 按内容做，
  /// 用户误选也能给出明确提示而不是解析出错。
  static const List<String> defaultMimeTypes = <String>[
    'application/zip',
    'application/x-zip-compressed',
    'application/json',
    'text/plain',
    '*/*',
  ];

  /// 当前平台是否实现了该通道（目前只有 Android 侧实现）。
  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  /// 打开系统文件选择器；用户取消时返回 `null`。
  Future<PickedFileData?> pick({List<String> mimeTypes = defaultMimeTypes}) async {
    final Map<Object?, Object?>? result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'pickFile',
      <String, Object>{'mimeTypes': mimeTypes},
    );
    if (result == null) return null;
    final Object? name = result['name'];
    final Object? bytes = result['bytes'];
    if (bytes is! Uint8List) return null;
    return PickedFileData(
      name: name is String && name.isNotEmpty ? name : 'backup',
      bytes: bytes,
    );
  }
}