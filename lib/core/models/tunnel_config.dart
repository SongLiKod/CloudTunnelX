import 'protocol_type.dart';

/// 隧道模式：临时穿透（快速测试） / 固定穿透（正式使用）
enum TunnelMode { quick, named }

/// 定时启停计划（需求：按时间段自动启动/停止隧道，支持跨天时段）
class TunSchedule {
  /// 是否启用定时计划
  bool enabled;

  /// 时段开始（24h 制 "HH:mm"）
  String start;

  /// 时段结束（24h 制 "HH:mm"，早于 start 表示跨天）
  String end;

  /// 每周生效的天（ISO 1=周一 … 7=周日），空列表表示每天
  List<int> weekdays;

  TunSchedule({
    this.enabled = false,
    this.start = '09:00',
    this.end = '18:00',
    List<int>? weekdays,
  }) : weekdays = weekdays ?? const [1, 2, 3, 4, 5];

  factory TunSchedule.fromJson(Map<String, dynamic> j) => TunSchedule(
        enabled: j['enabled'] as bool? ?? false,
        start: j['start'] as String? ?? '09:00',
        end: j['end'] as String? ?? '18:00',
        weekdays: (j['weekdays'] as List?)?.map((e) => e as int).toList() ??
            const [1, 2, 3, 4, 5],
      );

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'start': start, 'end': end, 'weekdays': weekdays};

  TunSchedule copyWith({
    bool? enabled,
    String? start,
    String? end,
    List<int>? weekdays,
  }) =>
      TunSchedule(
        enabled: enabled ?? this.enabled,
        start: start ?? this.start,
        end: end ?? this.end,
        weekdays: weekdays ?? this.weekdays,
      );

  /// 判断指定时间点是否处于计划时段内（考虑跨天，忽略星期）
  bool withinTime(int hour, int minute) {
    final a = _toMin(start), b = _toMin(end);
    final cur = hour * 60 + minute;
    if (a == b) return false; // 同一时刻视为不启用
    if (a < b) return cur >= a && cur < b;
    return cur >= a || cur < b; // 跨天时段（如 22:00-06:00）
  }

  bool activeOn(int weekday) => weekdays.isEmpty || weekdays.contains(weekday);

  static int _toMin(String t) {
    final p = t.split(':');
    final h = int.tryParse(p[0]) ?? 0;
    final m = p.length > 1 ? (int.tryParse(p[1]) ?? 0) : 0;
    return (h.clamp(0, 23)) * 60 + (m.clamp(0, 59));
  }

  /// 展示文案，如「周一~周五 09:00-18:00」
  String get label {
    final week = weekdays.isEmpty
        ? '每天'
        : switch (weekdays) {
            const [1, 2, 3, 4, 5] => '工作日',
            const [6, 7] => '周末',
            _ => '周${weekdays.map((d) => '一二三四五六日'[d - 1]).join('/')}',
          };
    return '$week $start-$end';
  }
}

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

  /// 所属 Cloudflare 账号 id（为空时使用默认账号，DNS 路由/校验作用于该账号）
  String? accountId;

  /// 定时启停计划（可选）
  TunSchedule? schedule;

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
    this.accountId,
    this.schedule,
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
        'accountId': accountId,
        'schedule': schedule?.toJson(),
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
        accountId: j['accountId'] as String?,
        schedule: j['schedule'] is Map
            ? TunSchedule.fromJson((j['schedule'] as Map).cast<String, dynamic>())
            : null,
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
    String? accountId,
    TunSchedule? schedule,
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
        accountId: accountId ?? this.accountId,
        schedule: schedule ?? this.schedule,
        autoRestore: autoRestore ?? this.autoRestore,
        createdAt: createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
}
