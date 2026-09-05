import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android 前台服务保活（技术文档 5.2.1）：隧道运行期间常驻通知，避免系统查杀

/// 通信端口初始化（必须在 runApp 前调用）
void initForegroundPort() {
  FlutterForegroundTask.initCommunicationPort();
}

/// TaskHandler 回调入口（必须为顶层函数）
@pragma('vm:entry-point')
void tunnelServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_TunnelTaskHandler());
}

class _TunnelTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    // 通知栏「停止隧道」按钮
    if (id == 'btn_stop_tunnels') {
      // 通过数据通道通知主 isolate 处理，避免直接依赖服务实例
      FlutterForegroundTask.sendDataToMain({'action': 'stop_all_tunnels'});
    }
  }

  @override
  void onNotificationPressed() {}
}

/// 权限申请（Android 13+ 通知权限、电池优化白名单）
Future<void> requestForegroundPermissions() async {
  if (!Platform.isAndroid) return;
  final permission = await FlutterForegroundTask.checkNotificationPermission();
  if (permission != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
}

/// 初始化服务参数
void initForegroundService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'cloudtunnelx_service',
      channelName: '云隧通隧道服务',
      channelDescription: '隧道后台运行保活通知，展示隧道运行状态',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(10000),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// 根据运行中隧道数量更新前台服务（需求 5.2.1 通知常驻提示：运行中/隧道数量）
/// [disconnectedCount] 为断线重连/异常的隧道数，>0 时在通知文案中提示
Future<void> updateForegroundService(int runningCount,
    {int disconnectedCount = 0}) async {
  if (!Platform.isAndroid) return;
  final running = runningCount > 0;
  final title = running
      ? (disconnectedCount > 0 ? '云隧通 · 隧道断线重连' : '云隧通 · 隧道运行中')
      : '云隧通';
  final text = !running
      ? '隧道未运行'
      : (disconnectedCount > 0
          ? '共 $running 条隧道运行中，$disconnectedCount 条断线重连'
          : '共 $running 条隧道正在穿透，保持后台连接');
  try {
    if (running) {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
          notificationButtons: const [
            NotificationButton(id: 'btn_stop_tunnels', text: '停止隧道'),
          ],
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: title,
          notificationText: text,
          notificationButtons: const [
            NotificationButton(id: 'btn_stop_tunnels', text: '停止隧道'),
          ],
          callback: tunnelServiceCallback,
        );
      }
    } else if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  } catch (_) {
    // 前台服务异常不影响隧道功能
  }
}
