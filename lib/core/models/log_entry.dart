import 'protocol_type.dart';

enum LogLevel { info, warn, error, success }

/// 日志条目（需求 3.4：按协议分类展示隧道运行日志）
class LogEntry {
  final DateTime time;
  final String tunnelId;
  final String tunnelName;
  final ProtocolType? protocol;
  final LogLevel level;
  final String message;

  /// 命中错误库时附带的修复方案
  final String? fixHint;

  LogEntry({
    required this.time,
    required this.tunnelId,
    required this.tunnelName,
    this.protocol,
    required this.level,
    required this.message,
    this.fixHint,
  });

  String get timeText =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
}
