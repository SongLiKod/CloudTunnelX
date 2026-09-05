import '../models/log_entry.dart';

/// 智能报错解析规则（需求 3.4 / 第 6 章：错误模式 → 通俗原因 + 修复方案）
class ErrorRule {
  final RegExp pattern;
  final LogLevel level;
  final String fixHint;
  const ErrorRule(this.pattern, this.level, this.fixHint);
}

class ErrorCatalog {
  /// 顺序匹配，命中即返回；覆盖需求文档第 6/7 章全部报错场景
  static final List<ErrorRule> rules = [
    // 用户已知报错：URL 拼写错误
    ErrorRule(
      RegExp(r'url.*拼写|拼写.*错误|spelling|invalid\s+url|malformed|bad\s+url|provided\s+service\s+url|service\s+url.*invalid|url.*not\s+valid|not\s+valid.*url|invalid.*origin', caseSensitive: false),
      LogLevel.error,
      '本地服务 URL 拼写或格式错误：请检查「本地IP:端口」是否正确、协议类型（HTTP/HTTPS/WS/TCP）是否与本地服务匹配，修正后重新启动隧道。',
    ),
    // 本地服务未启动 / 端口未监听
    ErrorRule(
      RegExp(r'connection\s+refused|unable\s+to\s+reach\s+the\s+origin|failed\s+to\s+connect\s+to\s+local|dial\s+tcp.*connectex|no\s*connection\s+could\s+be\s+made', caseSensitive: false),
      LogLevel.error,
      '本地服务连接失败（端口未监听）：请确认本地服务已启动，并检查本地 IP 与端口是否填写正确（如网页服务 80/8080、RDP 3389、MySQL 3306）。',
    ),
    // DNS 解析失败 / 域名未托管
    ErrorRule(
      RegExp(r'no\s+such\s+host|lookup\s+\S+\s+(failed|on)|dns|name\s+resolution|could\s+not\s+resolve', caseSensitive: false),
      LogLevel.error,
      '域名解析失败：请确认域名 DNS 已托管至 Cloudflare，子域名拼写无误；新解析记录需等待 1~5 分钟生效。',
    ),
    // 未登录 / 凭证缺失 / 鉴权失败
    ErrorRule(
      RegExp(r'unauthorized|authentication|cert\.pem|credential|api\.cloudflare\.com.*(401|403)|need\s+to\s+login|access\s+denied|forbidden', caseSensitive: false),
      LogLevel.error,
      'Cloudflare 凭证或鉴权失败：请到「设置」页完成 Cloudflare 登录授权（cert.pem），或检查固定隧道的 Tunnel Token 是否有效；TCP 隧道需确认 Access 鉴权配置完整。',
    ),
    // 路由 / 记录已存在
    ErrorRule(
      RegExp(r'already\s+exists|already\s+have|duplicate|record\s+conflict', caseSensitive: false),
      LogLevel.warn,
      'DNS 路由记录已存在：该子域名已被其他隧道/记录占用，可更换子域名，或到 Cloudflare 控制台删除旧记录后重新绑定。',
    ),
    // 隧道不存在
    ErrorRule(
      RegExp(r'tunnel\s+\S*\s*not\s+found|no\s+credential\s+file|credential\s+file.*not|tunnel\s+not\s+found', caseSensitive: false),
      LogLevel.error,
      '隧道或凭证文件不存在：隧道可能已被删除，或凭证 JSON 丢失；请在「固定穿透」页删除该隧道后重新创建。',
    ),
    // 端口占用
    ErrorRule(
      RegExp(r'address\s+already\s+in\s+use|bind:|only\s+one\s+usage\s+of\s+each\s+socket', caseSensitive: false),
      LogLevel.error,
      '本地端口被占用：请更换 metrics/监听端口，或结束占用该端口的进程后重试。',
    ),
    // 网络超时 / 断线
    ErrorRule(
      RegExp(r'timeout|timed?\s*out|i/o\s+timeout|handshake|connection\s+reset|broken\s+pipe|eof', caseSensitive: false),
      LogLevel.warn,
      '网络超时或连接中断：请检查本机网络与代理设置；程序将按 3s/8s/15s 阶梯自动重连。',
    ),
    // 边缘节点连接失败（QUIC/UDP 受限网络）
    ErrorRule(
      RegExp(r'failed\s+to\s+connect\s+to.*edge|dial\s+udp|quic|register.*tunnel.*failed', caseSensitive: false),
      LogLevel.error,
      '无法连接 Cloudflare 边缘节点：检查防火墙是否放行 UDP 7844/443 端口；受限网络可在配置中改用 http2 协议回退。',
    ),
    // WebSocket
    ErrorRule(
      RegExp(r'websocket|upgrade', caseSensitive: false),
      LogLevel.warn,
      'WebSocket 连接异常：cloudflared 自动兼容 WS 长连接，请确认后端服务支持 WS Upgrade，且协议类型选择了 WebSocket。',
    ),
    // TCP 鉴权（Access）
    ErrorRule(
      RegExp(r'access\s+(token|jwt)|cf-access|unauthorized\s+access', caseSensitive: false),
      LogLevel.error,
      'TCP Access 鉴权失败：四层穿透必须携带 Cloudflare Access 鉴权，请检查 Access 应用与策略配置，客户端需使用 cloudflared access tcp 命令接入。',
    ),
  ];

  static (LogLevel, String?) match(String raw) {
    for (final r in rules) {
      if (r.pattern.hasMatch(raw)) return (r.level, r.fixHint);
    }
    return (LogLevel.info, null);
  }
}
