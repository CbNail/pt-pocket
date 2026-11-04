package com.ptpocket.pt_pocket

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * 宿主 Activity：承载 Flutter 引擎，并提供 App 自己的文件选择通道。
 *
 * 通道 `ptpocket/file_picker`：
 * - `pickFile(mimeTypes: List<String>)` -> `{name: String, bytes: ByteArray}`；用户取消返回 null。
 *
 * 为什么不用第三方文件选择插件：AGP 9 下 `file_picker` / `file_selector_android` 都改为依赖
 * AGP 的**内建 Kotlin**（在 AGP 9 上不再自己 apply Kotlin 插件），而本工程按 Flutter 模板
 * 关闭了内建 Kotlin（`android/gradle.properties` 的 `android.builtInKotlin=false`），
 * 于是它们的 Kotlin 源码不会被任何一方编译，构建报 `cannot find symbol: FilePickerPlugin`。
 * 宿主模块的 Kotlin 由 Flutter 的 Gradle 插件编译，因此把选择器实现放在这里最稳。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "ptpocket/file_picker"
    private val pickRequestCode = 0x5054 // 'PT'
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "pickFile" -> pickFile(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "已有一个文件选择在进行中", null)
            return
        }
        val mimeTypes = call.argument<List<String>>("mimeTypes")
            ?: listOf("application/zip", "application/json", "*/*")

        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mimeTypes.size == 1) mimeTypes[0] else "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, pickRequestCode)
        } catch (error: Exception) {
            pendingResult = null
            result.error("no_picker", error.message ?: "无法打开系统文件选择器", null)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRequestCode) return
        val result = pendingResult ?: return
        pendingResult = null

        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // 用户取消
            return
        }
        try {
            val bytes = contentResolver.openInputStream(uri)?.use { input ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    out.write(buffer, 0, read)
                }
                out.toByteArray()
            }
            if (bytes == null) {
                result.error("read_failed", "无法读取所选文件（拿不到内容流）", null)
                return
            }
            result.success(mapOf("name" to displayName(uri), "bytes" to bytes))
        } catch (error: Exception) {
            result.error("read_failed", error.message ?: "读取文件失败", null)
        }
    }

    /** 取系统显示的文件名；取不到不影响导入，用默认名兜底。 */
    private fun displayName(uri: Uri): String {
        var name = "backup"
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) {
                    val value = cursor.getString(index)
                    if (!value.isNullOrEmpty()) name = value
                }
            }
        } catch (_: Exception) {
            // 文件名只是展示用，取不到就算了。
        }
        return name
    }
}