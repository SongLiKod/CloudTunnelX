import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

import 'core/models/tunnel_status.dart';
import 'core/services/app_controller.dart';
import 'core/services/tray_service.dart';

final TrayService trayService = TrayService();
bool _trayReady = false;

/// 已提醒过「断线/异常」的隧道集合：避免重连重试期间反复打扰，恢复后自动放行
final Set<String> _alertedTunnels = <String>{};

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

/// 监控隧道状态：断线重连/异常时「系统通知 + 窗口带前」提醒
/// （需求：后台静默运行也能第一时间感知隧道挂了）
void _watchTunnelErrors(AppController app) {
  // 首帧同步基线：启动时已在断线/异常中的隧道不当作新事件提醒
  for (final c in app.tunnels.all) {
    final st = app.tunnels.statusOf(c.id);
    if (st == TunnelStatus.reconnecting || st == TunnelStatus.error) {
      _alertedTunnels.add(c.id);
    }
  }
  app.tunnels.addListener(() {
    for (final c in app.tunnels.all) {
      final st = app.tunnels.statusOf(c.id);
      final unhealthy =
          st == TunnelStatus.reconnecting || st == TunnelStatus.error;
      if (unhealthy) {
        // 首次进入异常状态才提醒；重连重试期间保持静默
        if (_alertedTunnels.add(c.id)) {
          unawaited(_alertTunnelProblem(c.name, st));
        }
      } else {
        _alertedTunnels.remove(c.id);
      }
    }
  });
}

/// 断线/异常提醒：托盘系统通知（toast/气泡）+ 窗口带前
Future<void> _alertTunnelProblem(String name, TunnelStatus st) async {
  final reconnecting = st == TunnelStatus.reconnecting;
  try {
    await localNotifier.notify(LocalNotification(
      title: reconnecting ? '云隧通 · 隧道断线重连' : '云隧通 · 隧道异常',
      body: '「$name」'
          '${reconnecting ? '连接已断开，正在自动重连' : '运行异常，请打开界面查看'}',
    ));
  } catch (_) {
    // 通知失败不阻塞窗口带前
  }
  try {
    await windowManager.show(inactive: true);
    await windowManager.focus();
  } catch (_) {}
}

/// 托盘初始化（App 首帧后调用一次）
Future<void> setupTray(AppController app) async {
  if (kIsWeb || !Platform.isWindows || _trayReady) return;
  _trayReady = true;
  // 初始化系统通知（toast）通道；失败时退化为仅窗口带前提醒
  try {
    await localNotifier.setup(appName: '云隧通 CloudTunnelX');
  } catch (_) {}
  // 隧道异常/断线时提醒（需在托盘就绪后启用，避免启动期误报）
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
