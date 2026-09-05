import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/tunnel_config.dart';
import '../core/models/tunnel_status.dart';
import '../core/services/app_controller.dart';
import 'pages/domains_page.dart';
import 'pages/logs_page.dart';
import 'pages/overview_page.dart';
import 'pages/quick_tunnel_page.dart';
import 'pages/settings_page.dart';
import 'pages/tunnels_page.dart';

/// 双端自适应壳（技术文档 2.3.1）：宽屏 NavigationRail / 窄屏 NavigationBar
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _pages = [
    OverviewPage(),
    QuickTunnelPage(),
    TunnelsPage(),
    DomainsPage(),
    LogsPage(),
    SettingsPage(),
  ];

  static const _items = [
    (Icons.dashboard_outlined, Icons.dashboard_rounded, '总览', null),
    (Icons.bolt_outlined, Icons.bolt_rounded, '临时穿透', TunnelMode.quick),
    (Icons.dns_outlined, Icons.dns_rounded, '固定穿透', TunnelMode.named),
    (Icons.public_outlined, Icons.public_rounded, '域名管理', null),
    (Icons.terminal_outlined, Icons.terminal_rounded, '日志', null),
    (Icons.settings_outlined, Icons.settings_rounded, '设置', null),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final running = app.tunnels.runningCount;
    final activeCounts = _activeByMode(app);
    final wide = MediaQuery.of(context).size.width >= 860;

    final title = '云隧通 CloudTunnelX';

    final body = IndexedStack(index: _index, children: _pages);

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(children: [
        Expanded(
          child: Text(title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      ]),
    );

    return Scaffold(
      body: wide
          ? Row(children: [
              SizedBox(
                width: 88,
                child: Column(children: [
                  header,
                  Expanded(
                    child: Column(children: [
                      Expanded(
                        child: NavigationRail(
                          selectedIndex: _index,
                          onDestinationSelected: (i) => setState(() => _index = i),
                          labelType: NavigationRailLabelType.all,
                          destinations: [
                            for (final it in _items)
                              NavigationRailDestination(
                                icon: _NavIcon(
                                    it: it, activeCounts: activeCounts),
                                selectedIcon: Icon(it.$2),
                                label: Text(it.$3,
                                    style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                        ),
                      ),
                      _RunningBadge(running: running),
                    ]),
                  ),
                ]),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ])
          : Column(children: [
              header,
              Expanded(child: body),
            ]),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final it in _items)
                  NavigationDestination(
                    icon: _NavIcon(it: it, activeCounts: activeCounts),
                    selectedIcon: Icon(it.$2),
                    label: it.$3,
                  ),
              ],
            ),
    );
  }

  /// 统计各穿透模式下处于活跃状态（运行/启动/重连）的隧道数量，用于导航项角标
  Map<TunnelMode, int> _activeByMode(AppController app) {
    final counts = <TunnelMode, int>{TunnelMode.quick: 0, TunnelMode.named: 0};
    for (final c in app.tunnels.all) {
      final s = app.tunnels.statusOf(c.id);
      final active = s == TunnelStatus.running ||
          s == TunnelStatus.starting ||
          s == TunnelStatus.reconnecting;
      if (active) counts[c.mode] = counts[c.mode]! + 1;
    }
    return counts;
  }
}

/// 导航项图标：对应穿透模式有运行中隧道时，显示绿色数字角标（醒目样式）
class _NavIcon extends StatelessWidget {
  final (IconData, IconData, String, TunnelMode?) it;
  final Map<TunnelMode, int> activeCounts;
  const _NavIcon({required this.it, required this.activeCounts});

  @override
  Widget build(BuildContext context) {
    final count = it.$4 == null ? 0 : (activeCounts[it.$4] ?? 0);
    final icon = Icon(it.$1);
    if (count == 0) return icon;
    return Badge(
      label: Text('$count'),
      backgroundColor: Colors.green.shade400,
      textColor: Colors.black87,
      child: icon,
    );
  }
}

class _RunningBadge extends StatelessWidget {
  final int running;
  const _RunningBadge({required this.running});

  @override
  Widget build(BuildContext context) {
    final color = running > 0 ? Colors.green.shade300 : Colors.grey.shade500;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(running > 0 ? '运行 $running' : '空闲',
            style: TextStyle(fontSize: 10, color: color)),
      ]),
    );
  }
}
