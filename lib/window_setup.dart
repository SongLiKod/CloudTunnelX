import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/services/app_controller.dart';
import 'core/services/tray_service.dart';

final TrayService trayService = TrayService();
bool _trayReady = false;

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

/// 托盘初始化（App 首帧后调用一次）
Future<void> setupTray(AppController app) async {
  if (kIsWeb || !Platform.isWindows || _trayReady) return;
  _trayReady = true;
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
