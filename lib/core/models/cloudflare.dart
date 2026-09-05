/// Cloudflare 托管域名（Zone）
class CfZone {
  final String id;
  final String name;
  final String status;
  final bool paused;
  final String? planName;
  final String nameServers;
  final String? accountId;

  CfZone({
    required this.id,
    required this.name,
    required this.status,
    required this.paused,
    this.planName,
    required this.nameServers,
    this.accountId,
  });

  factory CfZone.fromJson(Map<String, dynamic> j) {
    final ns = (j['name_servers'] as List?)?.join(', ') ?? '';
    return CfZone(
      id: j['id'] as String,
      name: j['name'] as String,
      status: j['status'] as String? ?? 'unknown',
      paused: j['paused'] as bool? ?? false,
      planName: (j['plan'] as Map?)?['name'] as String?,
      nameServers: ns,
      accountId: (j['account'] as Map?)?['id'] as String?,
    );
  }
}

/// Cloudflare 命名隧道信息（连接状态查询）
class CfTunnelInfo {
  final String id;
  final String name;
  final int connections;

  CfTunnelInfo({required this.id, required this.name, required this.connections});

  factory CfTunnelInfo.fromJson(Map<String, dynamic> j) => CfTunnelInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        connections: ((j['connections'] as List?) ?? []).length,
      );
}

/// Cloudflare DNS 记录
class CfDnsRecord {
  final String id;
  final String zoneId;
  final String type;
  final String name;
  final String content;
  final bool proxied;
  final int ttl;
  final bool locked;
  final String? comment;

  CfDnsRecord({
    required this.id,
    required this.zoneId,
    required this.type,
    required this.name,
    required this.content,
    required this.proxied,
    required this.ttl,
    required this.locked,
    this.comment,
  });

  bool get isTunnel => content.endsWith('.cfargotunnel.com');

  factory CfDnsRecord.fromJson(Map<String, dynamic> j, String zoneId) => CfDnsRecord(
        id: j['id'] as String,
        zoneId: zoneId,
        type: j['type'] as String,
        name: j['name'] as String,
        content: j['content'] as String,
        proxied: j['proxied'] as bool? ?? false,
        ttl: j['ttl'] as int? ?? 1,
        locked: j['locked'] as bool? ?? false,
        comment: j['comment'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'zoneId': zoneId,
        'type': type,
        'name': name,
        'content': content,
        'proxied': proxied,
        'ttl': ttl,
        'locked': locked,
        'comment': comment,
      };
}
