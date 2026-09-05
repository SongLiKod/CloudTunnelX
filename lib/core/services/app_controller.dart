import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/cloudflare.dart';
import '../models/log_entry.dart';
import '../models/protocol_type.dart';
import '../models/tunnel_config.dart';
import '../models/tunnel_status.dart';
import '../../android_service.dart';
import 'app_updater.dart';
import 'binary_manager.dart';
import 'cloudflare_service.dart';
import 'config_repository.dart';
import 'log_service.dart';
import 'tunnel_service.dart';
import 'validation_service.dart';

/// 应用统一控制器：页面只面向该层操作，内部组合 校验/持久化/调度/日志
class AppController extends ChangeNotifier {
  final ConfigRepository repo;
  final LogService logs;
  final BinaryManager binaries;
  final TunnelService tunnels;
  final CloudflareService cf;
  final ValidationService validation = ValidationService();
  final AppUpdater updater = AppUpdater();

  /// 外观主题：浅色 / 深色 / 跟随系统
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    repo.setSetting('theme_mode', mode.name);
    notifyListeners();
  }

  static const _cfTokenKey = 'cf_api_token';

  /// 安全存储（Windows DPAPI / Android Keystore 加密），用于存放 API Token
  static const _secureStorage = FlutterSecureStorage();

  bool _bootRestored = false;

  AppController({
    required this.repo,
    required this.logs,
    required this.binaries,
    required this.tunnels,
    required this.cf,
  }) {
    tunnels.addListener(notifyListeners);
    logs.addListener(notifyListeners);
    binaries.addListener(notifyListeners);
    repo.addListener(notifyListeners);
    cf.addListener(notifyListeners);
    // Android：隧道运行状态联动前台服务通知（技术文档 5.2.1）
    if (!kIsWeb && Platform.isAndroid) {
      tunnels.addListener(_syncForegroundService);
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    }
    // 恢复外观主题偏好（默认跟随系统）
    final savedTheme = repo.getSetting<String>('theme_mode');
    if (savedTheme != null) {
      _themeMode = ThemeMode.values.firstWhere((e) => e.name == savedTheme,
          orElse: () => ThemeMode.system);
    }
    // 从安全存储恢复 Cloudflare API Token（异步，完成后自动迁移旧明文）
    _loadCfToken();
    // 应用自身版本更新：读取当前版本并静默检查一次 GitHub Release
    updater.addListener(notifyListeners);
    unawaited(updater.init());
    unawaited(updater.checkForUpdate());
  }

  /// 手动检查应用更新（设置页「关于」入口）
  Future<void> checkAppUpdate() => updater.checkForUpdate();

  /// 执行应用升级（Windows 静默替换重启 / Android 跳转下载）
  Future<void> upgradeApp() =>
      updater.downloadAndInstall(onExit: () => exit(0));

  /// 从安全存储读取 Token；若安全存储为空但 hive 中存在旧版明文，则迁移过去
  Future<void> _loadCfToken() async {
    try {
      var token = await _secureStorage.read(key: _cfTokenKey);
      if ((token == null || token.isEmpty) &&
          repo.getSetting<String>(_cfTokenKey) != null) {
        token = repo.getSetting<String>(_cfTokenKey);
        if (token != null && token.isNotEmpty) {
          await _secureStorage.write(key: _cfTokenKey, value: token);
          await repo.setSetting(_cfTokenKey, null);
        }
      }
      if (token != null && token.isNotEmpty) cf.setToken(token);
    } catch (_) {
      // 安全存储不可用时回退到旧的明文读取，保证功能可用
      cf.setToken(repo.getSetting<String>(_cfTokenKey));
    }
  }

  /// 保存并验证 Cloudflare API Token（域名管理所需），Token 加密存入安全存储
  Future<bool> saveCfToken(String token) async {
    final t = token.trim();
    try {
      await _secureStorage.write(key: _cfTokenKey, value: t);
      await repo.setSetting(_cfTokenKey, null); // 清除历史明文
    } catch (_) {
      await repo.setSetting(_cfTokenKey, t); // 安全存储不可用时的兜底
    }
    cf.setToken(t);
    return cf.verifyToken();
  }

  Future<void> clearCfToken() async {
    try {
      await _secureStorage.delete(key: _cfTokenKey);
    } catch (_) {}
    await repo.setSetting(_cfTokenKey, null);
    cf.setToken(null);
  }

  void _syncForegroundService() {
    updateForegroundService(tunnels.runningCount);
  }

  void _onTaskData(Object data) {
    if (data is Map && data['action'] == 'stop_all_tunnels') {
      stopAll();
    }
  }

  String _newId() {
    final rnd = Random();
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$t${rnd.nextInt(1 << 32).toRadixString(36)}';
  }

  /// 启动恢复（需求 3.6：开机自启后默认恢复上一次隧道配置）
  Future<void> restoreFromBoot() async {
    if (_bootRestored || !repo.ready) return;
    _bootRestored = true;
    for (final c in repo.loadTunnels()) {
      tunnels.registerConfig(c);
      if (c.autoRestore) {
        logs.log(
            tunnelId: c.id,
            tunnelName: c.name,
            protocol: c.protocol,
            level: LogLevel.info,
            message: '开机自启：正在恢复隧道 ${c.name}');
        await tunnels.start(c);
      }
    }
  }

  /// 临时穿透（需求 3.2.1）：校验 → 启动 → 记录
  Future<ValidationResult> startQuickTunnel({
    required ProtocolType protocol,
    required String localHost,
    required int localPort,
  }) async {
    final c = TunnelConfig(
      id: _newId(),
      mode: TunnelMode.quick,
      name: '临时-${protocol.label}-$localPort',
      protocol: protocol,
      localHost: localHost,
      localPort: localPort,
    );
    final vr = validation.validateQuick(c);
    if (vr.hasBlocking) return vr;

    // 本地服务连通性预检（需求 3.5：提前拦截无效配置）
    final up = await validation.localServiceUp(localHost, localPort);
    if (!up) {
      logs.log(
          tunnelId: c.id,
          tunnelName: c.name,
          protocol: protocol,
          level: LogLevel.warn,
          message: '本地服务 $localHost:$localPort 当前不可达',
          fixHint: '请先启动本地服务并确认端口监听，否则隧道建立后也无法转发流量。');
    }

    repo.saveTunnel(c);
    tunnels.registerConfig(c);
    tunnels.lastQuickTunnelId = c.id;
    await tunnels.start(c);
    return const ValidationResult([]);
  }

  /// 固定穿透创建（需求 3.2.2）：校验 → 创建隧道 → 路由绑定 → 保存 → 启动
  Future<(TunnelConfig?, ValidationResult)> createNamedTunnel({
    required String name,
    required ProtocolType protocol,
    required String localHost,
    required int localPort,
    String? subdomain,
    String? token,
    bool tokenMode = false,
    bool autoRestore = false,
    bool skipDnsCheck = false,
  }) async {
    final c = TunnelConfig(
      id: _newId(),
      mode: TunnelMode.named,
      name: name.trim(),
      protocol: protocol,
      localHost: localHost.trim(),
      localPort: localPort,
      subdomain: subdomain?.trim(),
      tunnelToken: tokenMode ? token?.trim() : null,
      autoRestore: autoRestore,
    );

    final vr = validation.validateNamed(c, tokenMode: tokenMode);
    if (vr.hasBlocking) return (null, vr);

    if (!tokenMode) {
      // DNS 托管校验（需求 3.5）
      final sd = (subdomain ?? '').trim();
      if (!skipDnsCheck && sd.isNotEmpty) {
        // 取最后两段作为根域名（如 sub.app.example.com → example.com）
        final root = ValidationService.rootDomainOf(sd);
        bool managed = false;
        var apiOk = false;
        // 优先用已配置的 CF API Token 校验：不受公网 DoH 可达性影响，结果更可靠
        if (cf.configured) {
          try {
            final zones = await cf.listZones();
            managed = bestZoneFor(root, zones) != null;
            apiOk = true; // API 查询成功，以 API 结论为准
          } catch (_) {
            // API 不可用，继续走 DoH 兜底
          }
        }
        if (!apiOk) {
          final doh = await validation.domainManagedByCloudflare(root);
          managed = doh == true;
          if (doh == null) {
            // DoH 也异常：网络问题，引导用户手动确认而非误报「未托管」
            return (null, ValidationResult([
              ValidationIssue(
                  '域名 $root 的 DNS 托管状态暂时无法确认（网络异常，API 与 DoH 均不可达）。请确认域名已在 Cloudflare 托管，或勾选「跳过 DNS 校验」后重试。')
            ]));
          }
        }
        if (!managed) {
          return (null, ValidationResult([
            ValidationIssue(
                '域名 $root 未托管在 Cloudflare（未检测到 Cloudflare NS 记录）。请先在域名注册商处把 DNS 服务器迁移至 Cloudflare，或勾选「跳过 DNS 校验」后重试。')
          ]));
        }
      }
      try {
        final uuid = await tunnels.createNamedTunnel(c.name);
        c.tunnelUuid = uuid;
        if (sd.isNotEmpty) {
          // 优先通过 Cloudflare API 创建 CNAME 路由（无需网页端操作），
          // 未配置 API Token 时回退到 cloudflared tunnel route dns 命令
          final apiOk = await _routeDnsViaApi(sd, uuid);
          if (!apiOk) {
            await tunnels.routeDns(uuid, sd);
          }
        }
      } catch (e) {
        // 隧道已创建但路由绑定失败时，回滚删除刚创建的隧道，避免遗留孤儿资源
        if (c.tunnelUuid != null) {
          try {
            await tunnels.deleteNamedTunnel(c);
          } catch (_) {}
          c.tunnelUuid = null;
        }
        final msg = e.toString().replaceFirst(RegExp(r'^\w+(State)?Error:\s*'), '');
        return (null, ValidationResult([ValidationIssue('Cloudflare 命令执行失败：$msg')]));
      }
    }

    await repo.saveTunnel(c);
    tunnels.registerConfig(c);
    await tunnels.start(c);
    return (c, const ValidationResult([]));
  }

  /// 在 zone 列表中为子域名挑选最长后缀匹配（可单测）
  /// 例：a.app.example.com 优先命中 app.example.com 而非 example.com
  static CfZone? bestZoneFor(String subdomain, List<CfZone> zones) {
    CfZone? zone;
    for (final z in zones) {
      if (subdomain == z.name || subdomain.endsWith('.${z.name}')) {
        if (zone == null || z.name.length > zone.name.length) zone = z;
      }
    }
    return zone;
  }

  /// 通过 Cloudflare API 创建/更新 DNS CNAME 路由，把 `subdomain` 指向隧道
  /// 返回 true 表示 API 已处理；false 表示需回退到 cloudflared 命令行方式
  Future<bool> _routeDnsViaApi(String subdomain, String tunnelUuid) async {
    if (!cf.configured) return false;
    try {
      final zones = await cf.listZones();
      final zone = bestZoneFor(subdomain, zones);
      if (zone == null) return false;

      final target = '$tunnelUuid.cfargotunnel.com';
      // 检查是否已存在同名 CNAME，存在则更新，否则创建
      final existing = await cf.listDnsRecords(zone.id, type: 'CNAME');
      CfDnsRecord? hit;
      for (final r in existing) {
        if (r.name.toLowerCase() == subdomain.toLowerCase()) {
          hit = r;
          break;
        }
      }
      if (hit != null) {
        await cf.updateDnsRecord(
          zoneId: zone.id,
          recordId: hit.id,
          content: target,
          proxied: true,
        );
      } else {
        await cf.createDnsRecord(
          zoneId: zone.id,
          type: 'CNAME',
          name: subdomain,
          content: target,
          proxied: true,
          comment: 'CloudTunnelX 自动创建',
        );
      }
      return true;
    } catch (e) {
      logs.log(
          tunnelId: 'system',
          tunnelName: '域名管理',
          level: LogLevel.warn,
          message: '通过 API 创建 DNS 路由失败，将回退到 cloudflared 命令：$e');
      return false;
    }
  }

  Future<void> updateTunnel(TunnelConfig c,
      {String? name, String? localHost, int? localPort, bool? autoRestore}) async {
    final updated = c.copyWith(
        name: name, localHost: localHost, localPort: localPort, autoRestore: autoRestore);
    await repo.saveTunnel(updated);
    tunnels.registerConfig(updated);
  }

  Future<void> deleteTunnel(TunnelConfig c) async {
    // 同步清理 DNS 路由，避免残留指向已删除隧道的孤儿 CNAME
    await _cleanupTunnelDns(c);
    await tunnels.deleteNamedTunnel(c);
    await repo.deleteTunnel(c.id);
  }

  /// 删除隧道对应的 DNS CNAME 记录（仅在已配置 API Token 时可执行）
  Future<void> _cleanupTunnelDns(TunnelConfig c) async {
    final sd = (c.subdomain ?? '').trim();
    if (sd.isEmpty || !cf.configured || c.isNamedTokenMode) return;
    try {
      final zones = await cf.listZones();
      final zone = bestZoneFor(sd, zones);
      if (zone == null) return;
      final records = await cf.listDnsRecords(zone.id, type: 'CNAME');
      for (final r in records) {
        if (r.name == sd && r.content == '$sd.cfargotunnel.com') {
          await cf.deleteDnsRecord(zone.id, r.id);
          logs.log(
              tunnelId: c.id,
              tunnelName: c.name,
              protocol: c.protocol,
              level: LogLevel.info,
              message: '已清理 DNS 路由记录：$sd');
        }
      }
    } catch (e) {
      // DNS 清理失败不阻塞隧道删除，仅记录提示
      logs.log(
          tunnelId: c.id,
          tunnelName: c.name,
          protocol: c.protocol,
          level: LogLevel.warn,
          message: 'DNS 路由记录清理失败：$e',
          fixHint: '可到「域名管理」页手动删除对应的 CNAME 记录。');
    }
  }

  Future<void> startTunnel(TunnelConfig c) => tunnels.start(c);

  Future<void> stopTunnel(String id) => tunnels.stop(id);

  Future<void> startAll() async {
    for (final c in tunnels.all) {
      final st = tunnels.statusOf(c.id);
      if (st == TunnelStatus.stopped || st == TunnelStatus.error) {
        await tunnels.start(c);
      }
    }
  }

  Future<void> stopAll() => tunnels.stopAll();

  /// 通过 Cloudflare API 查询隧道当前边缘连接数（需求：连接状态可视化）
  Future<int?> tunnelConnections(String uuid) async {
    if (!cf.configured) return null;
    try {
      final list = await cf.listTunnels(uuid: uuid);
      if (list.isEmpty) return 0;
      return list.first.connections;
    } catch (e) {
      logs.log(
          tunnelId: 'system',
          tunnelName: '连接状态查询',
          level: LogLevel.warn,
          message: '查询隧道边缘连接数失败：$e');
      return null;
    }
  }

  /// 导出全部隧道配置为 JSON 字符串（备份/迁移）
  String exportConfigsJson() {
    final list = repo.loadTunnels().map((c) => c.toJson()).toList();
    return const JsonEncoder.withIndent('  ')
        .convert({'app': 'CloudTunnelX', 'version': 1, 'tunnels': list});
  }

  /// 从 JSON 字符串导入隧道配置，返回导入成功的条数；格式非法时抛异常
  Future<int> importConfigsJson(String content) async {
    final root = jsonDecode(content);
    if (root is! Map || root['tunnels'] is! List) {
      throw const FormatException('非法的配置文件：缺少 tunnels 列表');
    }
    var count = 0;
    for (final item in root['tunnels'] as List) {
      try {
        final c = TunnelConfig.fromJson((item as Map).cast<String, dynamic>());
        if (c.id.isEmpty) continue;
        await repo.saveTunnel(c);
        tunnels.registerConfig(c);
        count++;
      } catch (_) {
        // 单条记录损坏不影响其余导入
      }
    }
    return count;
  }
}

