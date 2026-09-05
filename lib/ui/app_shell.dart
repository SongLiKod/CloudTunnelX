import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    (Icons.dashboard_outlined, Icons.dashboard_rounded, '总览'),
    (Icons.bolt_outlined, Icons.bolt_rounded, '临时穿透'),
    (Icons.dns_outlined, Icons.dns_rounded, '固定穿透'),
    (Icons.public_outlined, Icons.public_rounded, '域名管理'),
    (Icons.terminal_outlined, Icons.terminal_rounded, '日志'),
    (Icons.settings_outlined, Icons.settings_rounded, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final running = app.tunnels.runningCount;
    final wide = MediaQuery.of(context).size.width >= 860;

    final title = '云隧通 CloudTunnelX';

    final body = IndexedStack(index: _index, children: _pages);

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(children: [
        Icon(Icons.cloud_rounded, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        _RunningBadge(running: running),
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
                    child: NavigationRail(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final it in _items)
                          NavigationRailDestination(
                            icon: Badge(
                              isLabelVisible: false,
                              child: Icon(it.$1),
                            ),
                            selectedIcon: Icon(it.$2),
                            label: Text(it.$3, style: const TextStyle(fontSize: 12)),
                          ),
                      ],
                    ),
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
                    icon: Icon(it.$1),
                    selectedIcon: Icon(it.$2),
                    label: it.$3,
                  ),
              ],
            ),
    );
  }
}

class _RunningBadge extends StatelessWidget {
  final int running;
  const _RunningBadge({required this.running});

  @override
  Widget build(BuildContext context) {
    final color = running > 0 ? Colors.green.shade300 : Colors.grey.shade500;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.link_rounded, size: 13, color: color),
        const SizedBox(width: 5),
        Text('运行 $running',
            style: TextStyle(fontSize: 12, color: color)),
      ]),
    );
  }
}
