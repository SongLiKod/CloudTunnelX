import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../models/cloudflare.dart';
import '../models/log_entry.dart';
import '../models/protocol_type.dart';
import '../models/tunnel_config.dart';
import '../models/tunnel_status.dart';
import '../../android_service.dart';
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

  static const _cfTokenKey = 'cf_api_token';

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
    // 从持久化存储恢复 Cloudflare API Token
    cf.setToken(repo.getSetting<String>(_cfTokenKey));
  }

  /// 保存并验证 Cloudflare API Token（域名管理所需）
  Future<bool> saveCfToken(String token) async {
    await repo.setSetting(_cfTokenKey, token.trim());
    cf.setToken(token);
    return cf.verifyToken();
  }

  Future<void> clearCfToken() async {
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
        final parts = sd.split('.');
        // 取最后两段作为根域名（如 sub.app.example.com → example.com）
        final root = parts.length >= 2
            ? parts.sublist(parts.length - 2).join('.')
            : sd;
        final managed = await validation.domainManagedByCloudflare(root);
        if (!managed) {
          return (null, ValidationResult([
            const ValidationIssue(
                '域名 DNS 托管校验失败：未检测到 Cloudflare NS 记录。请先在域名注册商处把 DNS 服务器迁移至 Cloudflare，或勾选「跳过 DNS 校验」后重试。')
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

  /// 通过 Cloudflare API 创建/更新 DNS CNAME 路由，把 `subdomain` 指向隧道
  /// 返回 true 表示 API 已处理；false 表示需回退到 cloudflared 命令行方式
  Future<bool> _routeDnsViaApi(String subdomain, String tunnelUuid) async {
    if (!cf.configured) return false;
    try {
      final zones = await cf.listZones();
      // 匹配最长后缀的 zone（如 a.app.example.com 优先命中 app.example.com 而非 example.com）
      CfZone? zone;
      for (final z in zones) {
        if (subdomain == z.name || subdomain.endsWith('.${z.name}')) {
          if (zone == null || z.name.length > zone.name.length) zone = z;
        }
      }
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
    await tunnels.deleteNamedTunnel(c);
    await repo.deleteTunnel(c.id);
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
}

