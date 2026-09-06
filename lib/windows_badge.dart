import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xue_hua_app_badge/xue_hua_app_badge.dart';

/// Windows 任务栏角标缓存：避免重复设置相同数字
int? _lastTaskbarCount;

/// 同步 Windows 任务栏角标（数字 = 运行中的隧道数量，显示在任务栏按钮右下角）。
/// 基于 ITaskbarList3::SetOverlayIcon：窗口最小化时任务栏按钮仍在，角标可见；
/// 「关窗隐藏到托盘」会移除任务栏按钮，角标随之隐藏（对应托盘图标）。失败静默。
Future<void> updateWindowsTaskbarBadge(int runningCount) async {
  if (kIsWeb || !Platform.isWindows) return;
  if (_lastTaskbarCount == runningCount) return;
  _lastTaskbarCount = runningCount;
  try {
    if (runningCount > 0) {
      await XueHuaAppBadge.instance.set(runningCount);
    } else {
      await XueHuaAppBadge.instance.remove();
    }
  } catch (_) {
    // 任务栏角标异常不影响隧道功能
  }
}