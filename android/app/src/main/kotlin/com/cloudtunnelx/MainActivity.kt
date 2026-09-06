package com.cloudtunnelx

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
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
                    "launcherBadge" -> setLauncherBadge(call.argument<Int>("count") ?: 0, result)
                    else -> result.notImplemented()
                }
            }
    }

    /** 启动器图标数字徽标：count<=0 移除；否则通过一条携带 setNumber 的静默通知展示数量。
     *  说明：ShortcutBadger 已停更且在 Android 8.0+ 上不创建通知渠道，数字徽标永远不显示；
     *  改用系统标准的「通知数字徽标」机制（各厂商图标数字实现均基于通知 number）。 */
    private fun setLauncherBadge(count: Int, result: MethodChannel.Result) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            // Android 8.0 起强制要求通知渠道，未创建渠道的通知会被系统直接丢弃
            createBadgeChannel()
            if (count > 0) {
                val label = applicationInfo.loadLabel(packageManager).toString()
                val notification = Notification.Builder(this, BADGE_CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_tunnel)
                    .setContentTitle(label)
                    .setContentText("$count 条隧道正在穿透")
                    .setNumber(count)
                    .build()
                nm.notify(BADGE_NOTIFICATION_ID, notification)
            } else {
                nm.cancel(BADGE_NOTIFICATION_ID)
            }
            result.success(true)
        } catch (e: Exception) {
            // 该 ROM/系统（如 Pixel Android 13+ 仅显示通知点）不支持时静默
            result.success(false)
        }
    }

    private fun createBadgeChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(BADGE_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            BADGE_CHANNEL_ID,
            "隧道数量徽标",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "用于在桌面图标上显示运行中的隧道数量"
            setShowBadge(true)
            enableVibration(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(channel)
    }

    companion object {
        private const val BADGE_CHANNEL_ID = "cloudtunnelx_badge"
        private const val BADGE_NOTIFICATION_ID = 0xBAD6
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