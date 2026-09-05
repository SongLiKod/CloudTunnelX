import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/log_entry.dart';
import '../models/protocol_type.dart';
import 'error_catalog.dart';

/// 日志与报错解析服务（需求 3.4：实时输出 / 智能解析 / 导出 / 清空）
class LogService extends ChangeNotifier {
  static const int _maxEntries = 5000;

  /// 单文件上限（超出后滚动为 .1 备份）
  static const int _maxFileBytes = 2 * 1024 * 1024;

  final List<LogEntry> _entries = [];
  Directory? _logDir;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 初始化日志落盘目录（可选，未初始化时仅内存记录）
  void initLogDir(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      _logDir = d;
    } catch (_) {
      _logDir = null;
    }
  }

  /// 当前日志文件路径（未初始化落盘时为 null）
  String? get logFilePath =>
      _logDir == null ? null : '${_logDir!.path}${Platform.pathSeparator}cloudtunnelx.log';

  void _persist(LogEntry e) {
    final dir = _logDir;
    if (dir == null) return;
    try {
      final f = File(logFilePath!);
      if (f.existsSync() && f.lengthSync() > _maxFileBytes) {
        final rotated = File('${f.path}.1');
        if (rotated.existsSync()) rotated.deleteSync();
        f.renameSync(rotated.path);
      }
      final line =
          '[${e.time.toIso8601String()}] [${e.level.name.toUpperCase()}] [${e.tunnelName}/${e.protocol?.label ?? "-"}] ${e.message}';
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 落盘失败不影响主流程
    }
  }

  void log({
    required String tunnelId,
    required String tunnelName,
    ProtocolType? protocol,
    required LogLevel level,
    required String message,
    String? fixHint,
  }) {
    final entry = LogEntry(
      time: DateTime.now(),
      tunnelId: tunnelId,
      tunnelName: tunnelName,
      protocol: protocol,
      level: level,
      message: message.trim(),
      fixHint: fixHint,
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _persist(entry);
    notifyListeners();
  }

  /// 捕获 cloudflared 原始输出并智能解析（需求 3.3 通用状态与日志模块）
  void parseKernelLine({
    required String tunnelId,
    required String tunnelName,
    required ProtocolType protocol,
    required String rawLine,
  }) {
    final line = rawLine.trim();
    if (line.isEmpty) return;
    final isErr = line.contains(RegExp(r'ERROR|FATAL', caseSensitive: false));
    final isWarn = line.contains(RegExp(r'WARN', caseSensitive: false));
    final (level, hint) = ErrorCatalog.match(line);
    final effective = level == LogLevel.info
        ? (isErr ? LogLevel.error : (isWarn ? LogLevel.warn : LogLevel.info))
        : level;
    log(
      tunnelId: tunnelId,
      tunnelName: tunnelName,
      protocol: protocol,
      level: effective,
      message: line,
      fixHint: hint,
    );
  }

  List<LogEntry> filter({
    String? tunnelId,
    ProtocolType? protocol,
    LogLevel? minLevel,
  }) =>
      _entries.where((e) {
        if (tunnelId != null && e.tunnelId != tunnelId) return false;
        if (protocol != null && e.protocol != protocol) return false;
        if (minLevel == LogLevel.error &&
            e.level != LogLevel.error &&
            e.level != LogLevel.warn) {
          return false;
        }
        return true;
      }).toList();

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// 导出日志（需求 3.4），返回导出文件路径
  Future<String> export() async {
    final dir = Directory.systemTemp;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final f = File('${dir.path}${Platform.pathSeparator}cloudtunnelx_logs_$stamp.log');
    final buf = StringBuffer();
    for (final e in _entries) {
      buf.writeln(
          '[${e.time.toIso8601String()}] [${e.level.name.toUpperCase()}] [${e.tunnelName}/${e.protocol?.label ?? "-"}] ${e.message}');
      if (e.fixHint != null) buf.writeln('    ↳ 修复方案: ${e.fixHint}');
    }
    await f.writeAsString(buf.toString());
    return f.path;
  }

  /// 最近未处理的错误（用于异常弹窗提醒，需求 3.3）
  LogEntry? latestErrorFor(String tunnelId) {
    for (final e in _entries.reversed) {
      if (e.tunnelId == tunnelId &&
          (e.level == LogLevel.error || e.level == LogLevel.warn)) {
        return e;
      }
    }
    return null;
  }
}
