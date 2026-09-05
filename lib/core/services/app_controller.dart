import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/cf_account.dart';
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

  /// 历史单 Token 存储键（迁移为默认账号前使用）
  static const _cfTokenKey = 'cf_api_token';

  /// 多账号元数据存储键（JSON：[{id, name}]）
  static const _accountsKey = 'cf_accounts';

  /// 账号的 Token 加密存储键前缀
  static String _tokenKeyFor(String accountId) => 'cf_token_$accountId';

  /// 安全存储（Windows DPAPI / Android Keystore 加密），用于存放 API Token
  static const _secureStorage = FlutterSecureStorage();

  /// Cloudflare 多账号列表（首项为默认账号，主 cf 实例绑定其 Token）
  List<CfAccount> _accounts = [];
  List<CfAccount> get cfAccounts => List.unmodifiable(_accounts);

  /// 按账号缓存独立的 CloudflareService 实例（各自缓存账户 ID）
  final Map<String, CloudflareService> _cfServices = {};

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
    // 启动时恢复 Cloudflare 多账号：
    // 1. 读取账号元数据；2. 若为空且存在历史单 Token，迁移为「默认账号」；
    // 3. 将默认账号 Token 绑定到主 cf 实例（供隧道 DNS 自动路由等使用）
    _loadCfAccounts();
    // 定时启停：每分钟自动检查各隧道生效时段（需求：按时间段启停）
    Timer.periodic(const Duration(minutes: 1), (_) => _applySchedules());
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

  /// 恢复多账号列表；无账号时迁移历史单 Token 为「默认账号」
  Future<void> _loadCfAccounts() async {
    try {
      final saved = repo.getSetting<String>(_accountsKey);
      if (saved != null && saved.isNotEmpty) {
        final list = jsonDecode(saved) as List;
        _accounts = list
            .map((j) => CfAccount.fromJson(j as Map<String, dynamic>))
            .toList();
      }
      if (_accounts.isEmpty) {
        // 迁移历史 Token（安全存储优先，其次旧明文）
        var legacy = await _secureStorage.read(key: _cfTokenKey);
        if ((legacy == null || legacy.isEmpty) &&
            repo.getSetting<String>(_cfTokenKey) != null) {
          legacy = repo.getSetting<String>(_cfTokenKey);
        }
        if (legacy != null && legacy.isNotEmpty) {
          await _secureStorage.write(
              key: _tokenKeyFor('default'), value: legacy);
          await repo.setSetting(_cfTokenKey, null);
          _accounts = [CfAccount(id: 'default', name: '默认账号')];
        }
      }
      if (_accounts.isNotEmpty) {
        final t = await _readTokenFor(_accounts.first.id);
        if (t != null && t.isNotEmpty) cf.setToken(t);
      }
    } catch (_) {
      // 安全存储不可用时回退旧明文，保证功能可用
      cf.setToken(repo.getSetting<String>(_cfTokenKey));
    }
  }

  Future<String?> _readTokenFor(String accountId) async {
    try {
      final t = await _secureStorage.read(key: _tokenKeyFor(accountId));
      if (t != null && t.isNotEmpty) return t;
    } catch (_) {}
    // 安全存储不可用时的明文兜底
    final fallback = repo.getSetting<String>(_tokenKeyFor(accountId));
    return (fallback != null && fallback.isNotEmpty) ? fallback : null;
  }

  Future<void> _persistAccounts() =>
      repo.setSetting(_accountsKey, jsonEncode(_accounts.map((a) => a.toJson()).toList()));

  /// 添加 Cloudflare 账号（保存并验证 Token），成功后自动设为首页账号
  Future<bool> addCfAccount({required String name, required String token}) async {
    final t = token.trim();
    if (t.isEmpty) return false;
    final id = 'acct_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(0xFFFF)}';
    final displayName = name.trim().isEmpty ? '账号 ${_accounts.length + 1}' : name.trim();
    try {
      await _secureStorage.write(key: _tokenKeyFor(id), value: t);
      await repo.setSetting(_tokenKeyFor(id), null);
    } catch (_) {
      await repo.setSetting(_tokenKeyFor(id), t); // 安全存储不可用时的兜底
    }
    final s = CloudflareService()..setToken(t);
    final ok = await s.verifyToken();
    if (!ok) {
      // 校验失败回滚
      try {
        await _secureStorage.delete(key: _tokenKeyFor(id));
      } catch (_) {}
      await repo.setSetting(_tokenKeyFor(id), null);
      return false;
    }
    _accounts.add(CfAccount(id: id, name: displayName));
    _cfServices[id] = s;
    await _persistAccounts();
    if (_accounts.length == 1) cf.setToken(t);
    notifyListeners();
    return true;
  }

  /// 重命名账号
  Future<void> renameCfAccount(String id, String name) async {
    final a = _accounts.where((e) => e.id == id).firstOrNull;
    if (a == null) return;
    a.name = name.trim().isEmpty ? a.name : name.trim();
    await _persistAccounts();
    notifyListeners();
  }

  /// 删除账号（连带删除其 Token 与缓存实例）；删除默认账号后自动切换下一个为默认
  Future<void> removeCfAccount(String id) async {
    if (_accounts.every((e) => e.id != id)) return;
    try {
      await _secureStorage.delete(key: _tokenKeyFor(id));
    } catch (_) {}
    await repo.setSetting(_tokenKeyFor(id), null);
    _cfServices.remove(id);
    _accounts.removeWhere((e) => e.id == id);
    await _persistAccounts();
    // 默认账号变化时重新绑定主 cf
    if (_accounts.isNotEmpty) {
      final t = await _readTokenFor(_accounts.first.id);
      if (t != null && t.isNotEmpty) cf.setToken(t);
    } else {
      cf.setToken(null);
    }
    notifyListeners();
  }

  /// 获取某账号对应的 CloudflareService（缓存实例，避免重复获取账户 ID）
  Future<CloudflareService> serviceFor(String accountId) async {
    final cached = _cfServices[accountId];
    if (cached != null) return cached;
    final account =
        _accounts.where((e) => e.id == accountId).firstOrNull ?? _accounts.firstOrNull;
    if (account != null) {
      final t = await _readTokenFor(account.id);
      if (t != null && t.isNotEmpty) {
        final s = CloudflareService()..setToken(t);
        _cfServices[account.id] = s;
        return s;
      }
    }
    throw StateError('未配置 Cloudflare API Token');
  }

  /// 账号 Token 掩码（仅用于展示识别，如 ab12****）
  Future<String> tokenMaskFor(String accountId) async {
    final t = await _readTokenFor(accountId);
    if (t == null || t.isEmpty) return '';
    if (t.length <= 8) return '****';
    return '${t.substring(0, 4)}****${t.substring(t.length - 4)}';
  }

  /// 保存并验证 Cloudflare API Token（现有入口，作用于默认账号：无账号时自动创建）
  Future<bool> saveCfToken(String token) async {
    final t = token.trim();
    if (_accounts.isEmpty) return addCfAccount(name: '默认账号', token: t);
    final id = _accounts.first.id;
    try {
      await _secureStorage.write(key: _tokenKeyFor(id), value: t);
      await repo.setSetting(_tokenKeyFor(id), null);
    } catch (_) {
      await repo.setSetting(_tokenKeyFor(id), t); // 安全存储不可用时的兜底
    }
    cf.setToken(t);
    return cf.verifyToken();
  }

  Future<void> clearCfToken() async {
    if (_accounts.isEmpty) {
      cf.setToken(null);
      return;
    }
    await removeCfAccount(_accounts.first.id);
  }

  void _syncForegroundService() {
    // 统计断线重连/异常的隧道数量，供前台服务通知文案展示（需求：断线要能感知）
    var disconnected = 0;
    for (final c in tunnels.all) {
      final st = tunnels.statusOf(c.id);
      if (st == TunnelStatus.reconnecting || st == TunnelStatus.error) {
        disconnected++;
      }
    }
    updateForegroundService(
      tunnels.runningCount,
      disconnectedCount: disconnected,
    );
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
    // 立即执行一次定时计划校验：处于生效时段外的隧道即使配置了自恢复也不启动
    _applySchedules();
  }

  /// 定时启停校验：在生效时段且星期匹配的隧道自动启动，否则自动停止。
  /// 每分钟由调度器触发；启动恢复后也执行一次，保证配置/导入后立即生效。
  void _applySchedules() {
    final now = DateTime.now();
    for (final c in tunnels.all) {
      final s = c.schedule;
      if (s == null || !s.enabled || c.mode == TunnelMode.quick) continue;
      final inWindow = s.activeOn(now.weekday) && s.withinTime(now.hour, now.minute);
      final st = tunnels.statusOf(c.id);
      final active = st == TunnelStatus.running ||
          st == TunnelStatus.starting ||
          st == TunnelStatus.reconnecting;
      if (inWindow && !active) {
        logs.log(
            tunnelId: c.id,
            tunnelName: c.name,
            protocol: c.protocol,
            level: LogLevel.info,
            message: '定时计划：已到生效时段 ${s.label}，自动启动隧道');
        unawaited(tunnels.start(c));
      } else if (!inWindow && active) {
        logs.log(
            tunnelId: c.id,
            tunnelName: c.name,
            protocol: c.protocol,
            level: LogLevel.info,
            message: '定时计划：已过生效时段 ${s.label}，自动停止隧道');
        unawaited(tunnels.stop(c.id));
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
    String? accountId,
    TunSchedule? schedule,
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
      accountId: accountId,
      schedule: schedule,
      autoRestore: autoRestore,
    );

    final vr = validation.validateNamed(c, tokenMode: tokenMode);
    if (vr.hasBlocking) return (null, vr);

    if (!tokenMode) {
      // DNS 托管校验（需求 3.5）：优先用所属账号的 CF API Token 校验
      final sd = (subdomain ?? '').trim();
      if (!skipDnsCheck && sd.isNotEmpty) {
        // 取最后两段作为根域名（如 sub.app.example.com → example.com）
        final root = ValidationService.rootDomainOf(sd);
        bool managed = false;
        var apiOk = false;
        // 优先用 API Token 校验：不受公网 DoH 可达性影响，结果更可靠
        if (cf.configured || accountId != null) {
          try {
            final svc = accountId == null ? cf : await serviceFor(accountId);
            if (svc.configured) {
              final zones = await svc.listZones();
              managed = bestZoneFor(root, zones) != null;
              apiOk = true; // API 查询成功，以 API 结论为准
            }
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
          final apiOk = await _routeDnsViaApi(sd, uuid, accountId);
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
  Future<bool> _routeDnsViaApi(String subdomain, String tunnelUuid,
      [String? accountId]) async {
    final CloudflareService svc;
    try {
      svc = accountId == null ? cf : await serviceFor(accountId);
    } catch (_) {
      return false;
    }
    if (!svc.configured) return false;
    try {
      final zones = await svc.listZones();
      final zone = bestZoneFor(subdomain, zones);
      if (zone == null) return false;

      final target = '$tunnelUuid.cfargotunnel.com';
      // 检查是否已存在同名 CNAME，存在则更新，否则创建
      final existing = await svc.listDnsRecords(zone.id, type: 'CNAME');
      CfDnsRecord? hit;
      for (final r in existing) {
        if (r.name.toLowerCase() == subdomain.toLowerCase()) {
          hit = r;
          break;
        }
      }
      if (hit != null) {
        await svc.updateDnsRecord(
          zoneId: zone.id,
          recordId: hit.id,
          content: target,
          proxied: true,
        );
      } else {
        await svc.createDnsRecord(
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
      {String? name,
      String? localHost,
      int? localPort,
      bool? autoRestore,
      String? accountId,
      TunSchedule? schedule}) async {
    final updated = c.copyWith(
        name: name,
        localHost: localHost,
        localPort: localPort,
        autoRestore: autoRestore,
        accountId: accountId,
        schedule: schedule);
    await repo.saveTunnel(updated);
    tunnels.registerConfig(updated);
    // 保存后立即校验一次定时计划，改动即时生效
    _applySchedules();
  }

  Future<void> deleteTunnel(TunnelConfig c) async {
    // 同步清理 DNS 路由，避免残留指向已删除隧道的孤儿 CNAME
    await _cleanupTunnelDns(c);
    await tunnels.deleteNamedTunnel(c);
    await repo.deleteTunnel(c.id);
  }

  /// 删除隧道对应的 DNS CNAME 记录（已在所属账号配置 API Token 时可执行）
  Future<void> _cleanupTunnelDns(TunnelConfig c) async {
    final sd = (c.subdomain ?? '').trim();
    if (sd.isEmpty || c.isNamedTokenMode) return;
    final CloudflareService svc;
    try {
      svc = c.accountId == null ? cf : await serviceFor(c.accountId!);
    } catch (_) {
      return;
    }
    if (!svc.configured) return;
    try {
      final zones = await svc.listZones();
      final zone = bestZoneFor(sd, zones);
      if (zone == null) return;
      final records = await svc.listDnsRecords(zone.id, type: 'CNAME');
      for (final r in records) {
        if (r.name == sd && r.content == '$sd.cfargotunnel.com') {
          await svc.deleteDnsRecord(zone.id, r.id);
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
  Future<int?> tunnelConnections(String uuid, {String? accountId}) async {
    final CloudflareService svc;
    try {
      svc = accountId == null ? cf : await serviceFor(accountId);
    } catch (_) {
      return null;
    }
    if (!svc.configured) return null;
    try {
      final list = await svc.listTunnels(uuid: uuid);
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

