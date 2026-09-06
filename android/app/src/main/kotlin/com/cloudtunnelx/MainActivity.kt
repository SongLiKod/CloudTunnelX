package com.cloudtunnelx

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 暴露内置 so 安装目录（Android 10+ 唯一允许执行程序的位置）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.cloudtunnelx/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" ->
                        result.success(applicationContext.applicationInfo.nativeLibraryDir)
                    "installApk" -> installApk(call.argument<String>("filePath"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /** 应用内更新：调起系统安装器安装更新 APK（先经 FileProvider 共享给安装器） */
    private fun installApk(filePath: String?, result: MethodChannel.Result) {
        if (filePath == null) {
            result.error("BAD_ARG", "filePath 缺失", null)
            return
        }
        val file = File(filePath)
        if (!file.exists()) {
            result.error("APK_NOT_FOUND", "更新包不存在：$filePath", null)
            return
        }
        // Android 8+ "安装未知应用"需用户授权；未授权时引导到系统设置页
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName")
                    )
                )
            } catch (_: Exception) {
                // 部分 ROM 无此设置页，直接尝试调起安装器
            } finally {
                result.success("NEED_PERMISSION")
            }
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(intent)
            result.success("OK")
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message, e.stackTraceToString())
        }
    }
}