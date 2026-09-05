import 'package:system_tray/system_tray.dart';

/// Windows 系统托盘（技术文档 4.2：托盘常驻 + 快捷菜单：启停隧道/打开界面/复制地址/退出）
class TrayService {
  final SystemTray _tray = SystemTray();

  Future<void> init({
    required Future<void> Function() onShow,
    required Future<void> Function() onStartAll,
    required Future<void> Function() onStopAll,
    required Future<void> Function() onCopyUrl,
    required Future<void> Function() onExit,
  }) async {
    try {
      await _tray.initSystemTray(
        title: '云隧通',
        iconPath: 'assets/icon.ico',
        toolTip: '云隧通 CloudTunnelX · 全协议内网穿透',
      );

      final menu = Menu();
      menu.buildFrom([
        MenuItemLabel(label: '显示主界面', onClicked: (item) async => onShow()),
        MenuSeparator(),
        MenuItemLabel(label: '启动全部隧道', onClicked: (item) async => onStartAll()),
        MenuItemLabel(label: '停止全部隧道', onClicked: (item) async => onStopAll()),
        MenuSeparator(),
        MenuItemLabel(label: '复制公网访问地址', onClicked: (item) async => onCopyUrl()),
        MenuSeparator(),
        MenuItemLabel(label: '退出', onClicked: (item) async => onExit()),
      ]);
      await _tray.setContextMenu(menu);

      _tray.registerSystemTrayEventHandler((eventName) {
        if (eventName == kSystemTrayEventClick ||
            eventName == kSystemTrayEventDoubleClick) {
          onShow();
        }
      });
    } catch (_) {
      // 托盘初始化失败不影响主界面
    }
  }

  Future<void> dispose() async {
    try {
      await _tray.destroy();
    } catch (_) {}
  }
}
