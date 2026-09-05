import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/tunnel_config.dart';

class ValidationIssue {
  final String message;
  final bool blocking;
  const ValidationIssue(this.message, {this.blocking = true});
}

class ValidationResult {
  final List<ValidationIssue> issues;
  const ValidationResult(this.issues);
  bool get ok => issues.isEmpty;
  bool get hasBlocking => issues.any((i) => i.blocking);
}

/// 通用参数校验模块（技术文档 3.2 / 需求 3.5）：
/// URL/端口格式、端口占用、本地服务连通、DNS 托管、协议匹配。
class ValidationService {
  static final _hostRe = RegExp(
      r'^(localhost|(\d{1,3}\.){3}\d{1,3}|(\[[0-9a-fA-F:]+\])|([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*))$');

  ValidationResult validateQuick(TunnelConfig c) {
    final issues = <ValidationIssue>[];
    issues.addAll(_validateBasic(c));
    return ValidationResult(issues);
  }

  ValidationResult validateNamed(TunnelConfig c, {bool tokenMode = false}) {
    final issues = <ValidationIssue>[];
    issues.addAll(_validateBasic(c));

    if (c.name.trim().isEmpty) {
      issues.add(const ValidationIssue('隧道名称不能为空'));
    }

    if (!tokenMode) {
      if (c.protocol.isWeb) {
        final sd = (c.subdomain ?? '').trim();
        if (sd.isEmpty) {
          issues.add(const ValidationIssue('网页协议必须绑定已托管 Cloudflare 的子域名（如 app.example.com）'));
        } else if (!_isDomain(sd)) {
          issues.add(const ValidationIssue('子域名格式不合法，应为形如 app.example.com 的域名，避免 URL 拼写错误'));
        }
      } else {
        // TCP：不支持裸端口暴露，需 DNS 入口 + 客户端 Access 鉴权接入
        final sd = (c.subdomain ?? '').trim();
        if (sd.isEmpty) {
          issues.add(const ValidationIssue(
              'TCP 协议需配置入口子域名，客户端通过 cloudflared access tcp 接入（CF 不支持裸端口公网暴露）'));
        } else if (!_isDomain(sd)) {
          issues.add(const ValidationIssue('子域名格式不合法'));
        }
      }
    }
    return ValidationResult(issues);
  }

  List<ValidationIssue> _validateBasic(TunnelConfig c) {
    final issues = <ValidationIssue>[];
    final host = c.localHost.trim();
    if (host.isEmpty) {
      issues.add(const ValidationIssue('本地 IP 不能为空'));
    } else if (!_hostRe.hasMatch(host)) {
      issues.add(ValidationIssue('本地 IP 格式不合法：$host'));
    }
    final port = c.localPort;
    if (port < 1 || port > 65535) {
      issues.add(const ValidationIssue('本地端口必须在 1~65535 之间'));
    }
    return issues;
  }

  bool _isDomain(String s) =>
      RegExp(r'^(?=.{4,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$')
          .hasMatch(s);

  /// 本地服务端口连通性检测（需求 3.5 通用校验）
  Future<bool> localServiceUp(String host, int port,
      {Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final addr = host == 'localhost' ? InternetAddress.loopbackIPv4 : null;
      final sock = addr != null
          ? await Socket.connect(addr, port, timeout: timeout)
          : await Socket.connect(host, port, timeout: timeout);
      sock.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// metrics 端口占用检测
  Future<bool> portFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 协议与配置匹配校验（技术文档 3.2：TCP 不填网页域名场景 / HTTP 不填 TCP 端口）
  String? protocolMatchHint(TunnelConfig c) {
    if (c.protocol.isWeb && (c.localPort == 3389 || c.localPort == 22)) {
      return '提示：RDP/SSH 属 TCP 服务，建议协议选择 TCP 并配置入口域名，而非网页协议。';
    }
    if (!c.protocol.isWeb && (c.localPort == 80 || c.localPort == 443)) {
      return '提示：80/443 通常是网页服务，建议协议选择 HTTP/HTTPS。';
    }
    return null;
  }

  /// 从子域名提取根域名（取最后两段）
  /// 例：sub.app.example.com → example.com；example.com → example.com
  static String rootDomainOf(String subdomain) {
    final parts = subdomain.split('.');
    return parts.length >= 2
        ? parts.sublist(parts.length - 2).join('.')
        : subdomain;
  }

  /// 域名 DNS 托管校验：通过 DoH 查询 NS 记录是否指向 Cloudflare
  /// 返回 true=已托管；false=确认未托管；null=网络异常无法判定
  Future<bool?> domainManagedByCloudflare(String domain) async {
    try {
      final res = await http.get(
        Uri.parse('https://cloudflare-dns.com/dns-query?name=$domain&type=NS'),
        headers: {'accept': 'application/dns-json'},
      ).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body = res.body.toLowerCase();
      return body.contains('.ns.cloudflare.com');
    } catch (_) {
      return null;
    }
  }

  /// 子域名路由生效校验：CNAME 应指向 `<tunnel-id>`.cfargotunnel.com
  Future<bool> subdomainRouted(String subdomain) async {
    try {
      final res = await http.get(
        Uri.parse('https://cloudflare-dns.com/dns-query?name=$subdomain&type=CNAME'),
        headers: {'accept': 'application/dns-json'},
      ).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return false;
      return res.body.toLowerCase().contains('cfargotunnel.com');
    } catch (_) {
      return false;
    }
  }

  /// 全量校验（创建固定隧道前调用，需求 3.2.2 智能自动校验）
  Future<ValidationResult> validateNamedFull(TunnelConfig c) async {
    final issues = <ValidationIssue>[...validateNamed(c).issues];
    if (issues.hasBlocking) return ValidationResult(issues);

    final up = await localServiceUp(c.localHost, c.localPort);
    if (!up) {
      issues.add(ValidationIssue(
          '本地服务 ${c.localHost}:${c.localPort} 当前不可达：请先启动本地服务（穿透会在服务可用后正常转发）',
          blocking: false));
    }
    final sd = (c.subdomain ?? '').trim();
    if (sd.isNotEmpty) {
      final root = ValidationService.rootDomainOf(sd);
      final managed = await domainManagedByCloudflare(root);
      if (managed == null) {
        issues.add(ValidationIssue(
            '无法确认域名 $root 的 DNS 托管状态（网络异常，DoH 查询不可达）',
            blocking: false));
      } else if (!managed) {
        issues.add(ValidationIssue(
            '域名 $root 的 NS 记录未指向 Cloudflare：请先在域名注册商处将 DNS 托管迁移至 Cloudflare'));
      }
    }
    return ValidationResult(issues);
  }
}

extension _ListX on List<ValidationIssue> {
  bool get hasBlocking => any((i) => i.blocking);
}
