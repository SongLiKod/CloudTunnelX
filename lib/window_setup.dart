import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/models/tunnel_status.dart';
import 'core/services/app_controller.dart';
import 'core/services/tray_service.dart';

final TrayService trayService = TrayService();
bool _trayReady = false;
bool _alertHandled = false;

/// Windows 专属窗口能力（技术文档 4.2）：窗口尺寸、关窗最小化至托盘
Future<void> setupWindow() async {
  if (kIsWeb || !Platform.isWindows) return;
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1120, 760),
    minimumSize: Size(920, 640),
    title: '云隧通 CloudTunnelX · 全协议内网穿透',
    center: true,
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  await windowManager.setPreventClose(true);
  windowManager.addListener(_WindowCloseListener());
}

/// 监控隧道状态：出现「异常」时把窗口带到前台提醒（后台静默运行也能感知）
void _watchTunnelErrors(AppController app) {
  // 首次调用同步一次基线，避免把历史异常误当作新事件
  _alertHandled =
      app.tunnels.all.any((c) => app.tunnels.statusOf(c.id) == TunnelStatus.error);
  app.tunnels.addListener(() async {
    if (_alertHandled) return;
    for (final c in app.tunnels.all) {
      if (app.tunnels.statusOf(c.id) == TunnelStatus.error) {
        _alertHandled = true;
        try {
          await windowManager.show(inactive: true);
          await windowManager.focus();
        } catch (_) {}
        return;
      }
    }
  });
}

/// 托盘初始化（App 首帧后调用一次）
Future<void> setupTray(AppController app) async {
  if (kIsWeb || !Platform.isWindows || _trayReady) return;
  _trayReady = true;
  // 隧道异常时闪烁任务栏提醒（需在托盘就绪后启用，避免启动期误报）
  _watchTunnelErrors(app);
  await trayService.init(
    onShow: () async {
      await windowManager.show();
      await windowManager.focus();
    },
    onStartAll: () async => app.startAll(),
    onStopAll: () async => app.stopAll(),
    // 需求 3.6 托盘快捷操作：复制公网访问地址
    onCopyUrl: () async {
      final data = ClipboardData(text: app.tunnels.publicUrlSummary);
      await Clipboard.setData(data);
    },
    onExit: () async {
      await app.stopAll();
      await trayService.dispose();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      exit(0);
    },
  );
}

class _WindowCloseListener extends WindowListener {
  @override
  void onWindowClose() async {
    // 关窗不退出：隐藏至托盘后台静默运行（需求 3.6）
    if (kIsWeb || !Platform.isWindows) {
      await windowManager.destroy();
      return;
    }
    await windowManager.hide();
  }
}
