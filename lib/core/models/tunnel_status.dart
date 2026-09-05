/// 隧道运行状态（需求文档 3.1：运行中 / 已停止 / 异常，另含启动中与重连中）
enum TunnelStatus { stopped, starting, running, reconnecting, error }

extension TunnelStatusX on TunnelStatus {
  String get label => switch (this) {
        TunnelStatus.stopped => '已停止',
        TunnelStatus.starting => '启动中',
        TunnelStatus.running => '运行中',
        TunnelStatus.reconnecting => '重连中',
        TunnelStatus.error => '异常',
      };
}

/// 单条隧道运行时数据（配置 + 实时状态 + 统计）
class TunnelRuntime {
  final String id;
  TunnelStatus status;
  String? publicUrl;
  String? lastError;
  DateTime? startedAt;

  /// 简要流量统计（cloudflared /metrics 解析，需求 3.1）
  int requestCount;
  int bytesCount;

  /// TCP 场景下客户端接入提示（cloudflared access 命令）
  String? accessHint;

  TunnelRuntime({
    required this.id,
    this.status = TunnelStatus.stopped,
    this.publicUrl,
    this.lastError,
    this.startedAt,
    this.requestCount = 0,
    this.bytesCount = 0,
    this.accessHint,
  });

  Duration? get uptime =>
      startedAt == null ? null : DateTime.now().difference(startedAt!);
}

/// 流量时序采样点（用于流量曲线展示）
class TrafficPoint {
  final DateTime time;

  /// 本采样周期内传输字节数（增量）
  final int bytes;

  const TrafficPoint({required this.time, required this.bytes});
}
