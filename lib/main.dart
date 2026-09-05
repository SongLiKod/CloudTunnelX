import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/services/app_controller.dart';
import 'core/services/binary_manager.dart';
import 'core/services/cloudflare_service.dart';
import 'core/services/config_repository.dart';
import 'core/services/log_service.dart';
import 'core/services/tunnel_service.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';
import 'window_setup.dart';
import 'android_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows：窗口初始化 + 关窗最小化到托盘（技术文档 4.2）
  if (!kIsWeb && Platform.isWindows) {
    await setupWindow();
  }

  // Android：前台服务通信端口初始化（技术文档 5.2.1）
  if (!kIsWeb && Platform.isAndroid) {
    initForegroundPort();
  }

  final repo = ConfigRepository();
  await repo.init();

  final binaries = BinaryManager();
  final logs = LogService();
  final tunnels = TunnelService(binaries: binaries, logs: logs);
  final cf = CloudflareService();
  final app = AppController(
      repo: repo, logs: logs, binaries: binaries, tunnels: tunnels, cf: cf);

  // 静默检测内核位置（内置 bin → 系统 PATH），失败不阻塞启动
  // ignore: unawaited_futures
  binaries.resolveBinary();

  runApp(CloudTunnelXApp(controller: app));
}

class CloudTunnelXApp extends StatelessWidget {
  final AppController controller;
  const CloudTunnelXApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        title: '云隧通 CloudTunnelX',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: AppBootstrap(controller: controller),
      ),
    );
  }
}

/// 启动引导：恢复上一次隧道配置（需求 3.6 开机自启/默认保留配置）
class AppBootstrap extends StatefulWidget {
  final AppController controller;
  const AppBootstrap({super.key, required this.controller});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  @override
  void initState() {
    super.initState();
    // 异步恢复，不阻塞首帧；并初始化托盘/前台服务
    Future.microtask(() async {
      if (!kIsWeb && Platform.isWindows) {
        await setupTray(widget.controller);
      }
      if (!kIsWeb && Platform.isAndroid) {
        await requestForegroundPermissions();
        initForegroundService();
      }
      await widget.controller.restoreFromBoot();
    });
  }

  @override
  Widget build(BuildContext context) => const AppShell();
}
