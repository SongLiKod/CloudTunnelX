import 'protocol_type.dart';

/// 隧道模式：临时穿透（快速测试） / 固定穿透（正式使用）
enum TunnelMode { quick, named }

/// 隧道持久化配置模型（需求文档 3.2）
class TunnelConfig {
  final String id;
  TunnelMode mode;
  String name;
  ProtocolType protocol;

  /// 本地服务地址（默认 127.0.0.1）
  String localHost;
  int localPort;

  /// 固定模式绑定的自有子域名（网页协议必填，如 app.example.com）
  String? subdomain;

  /// 固定模式 · Cloudflare 控制台 Token（远程管理模式，与 cert 登录二选一）
  String? tunnelToken;

  /// 固定模式 · `cloudflared tunnel create` 生成的隧道 UUID
  String? tunnelUuid;

  /// 是否开机自启后自动恢复该隧道
  bool autoRestore;

  final int createdAt;
  int updatedAt;

  TunnelConfig({
    required this.id,
    required this.mode,
    required this.name,
    required this.protocol,
    this.localHost = '127.0.0.1',
    required this.localPort,
    this.subdomain,
    this.tunnelToken,
    this.tunnelUuid,
    this.autoRestore = false,
    int? createdAt,
    int? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  /// 公网访问入口（临时模式运行后填充临时域名；固定模式为绑定子域名）
  String? get publicHost {
    if (mode == TunnelMode.named && (subdomain?.isNotEmpty ?? false)) {
      return subdomain;
    }
    return null;
  }

  bool get isNamedTokenMode =>
      mode == TunnelMode.named && (tunnelToken?.trim().isNotEmpty ?? false);

  Map<String, dynamic> toJson() => {
        'id': id,
        'mode': mode.name,
        'name': name,
        'protocol': protocol.name,
        'localHost': localHost,
        'localPort': localPort,
        'subdomain': subdomain,
        'tunnelToken': tunnelToken,
        'tunnelUuid': tunnelUuid,
        'autoRestore': autoRestore,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory TunnelConfig.fromJson(Map<String, dynamic> j) => TunnelConfig(
        id: j['id'] as String,
        mode: TunnelMode.values.firstWhere((e) => e.name == j['mode'],
            orElse: () => TunnelMode.quick),
        name: j['name'] as String? ?? '未命名隧道',
        protocol:
            ProtocolType.fromName(j['protocol'] as String?),
        localHost: j['localHost'] as String? ?? '127.0.0.1',
        localPort: j['localPort'] as int? ?? 80,
        subdomain: j['subdomain'] as String?,
        tunnelToken: j['tunnelToken'] as String?,
        tunnelUuid: j['tunnelUuid'] as String?,
        autoRestore: j['autoRestore'] as bool? ?? false,
        createdAt: j['createdAt'] as int?,
        updatedAt: j['updatedAt'] as int?,
      );

  TunnelConfig copyWith({
    String? name,
    ProtocolType? protocol,
    String? localHost,
    int? localPort,
    String? subdomain,
    String? tunnelToken,
    String? tunnelUuid,
    bool? autoRestore,
  }) =>
      TunnelConfig(
        id: id,
        mode: mode,
        name: name ?? this.name,
        protocol: protocol ?? this.protocol,
        localHost: localHost ?? this.localHost,
        localPort: localPort ?? this.localPort,
        subdomain: subdomain ?? this.subdomain,
        tunnelToken: tunnelToken ?? this.tunnelToken,
        tunnelUuid: tunnelUuid ?? this.tunnelUuid,
        autoRestore: autoRestore ?? this.autoRestore,
        createdAt: createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
}
