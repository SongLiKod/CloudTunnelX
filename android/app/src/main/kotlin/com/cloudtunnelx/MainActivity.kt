package com.cloudtunnelx

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 暴露内置 so 安装目录（Android 10+ 唯一允许执行程序的位置）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.cloudtunnelx/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" ->
                        result.success(applicationContext.applicationInfo.nativeLibraryDir)
                    else -> result.notImplemented()
                }
            }
    }
}