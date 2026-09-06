import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/log_entry.dart';
import '../models/protocol_type.dart';
import '../models/tunnel_config.dart';
import '../models/tunnel_status.dart';
import 'binary_manager.dart';
import 'log_service.dart';

/// 隧道调度核心（技术文档 2.3.2 业务调度层，双端通用）：
/// 命令组装、进程管理、状态监听、断线重连、metrics 流量统计。
class TunnelService extends ChangeNotifier {
  final BinaryManager binaries;
  final LogService logs;

  final Map<String, Process> _processes = {};
  final Map<String, TunnelConfig> _configs = {};
  final Map<String, TunnelRuntime> _runtimes = {};
  final Map<String, Timer?> _metricTimers = {};
  final Map<String, int> _metricPorts = {};
  final Map<String, List<int>> _retrySchedule = {};
  final Map<String, bool> _userStop = {};
  final Map<String, List<TrafficPoint>> _trafficSeries = {};
  final Map<String, int> _prevBytes = {};
  final Set<String> _metricsWarned = {};
  final Set<String> _metricsLogged = {};

  /// 流量时序采样上限（5s 一次，约覆盖 10 分钟）
  static const int _maxSeriesPoints = 120;

  /// 最近一次临时隧道 id（快速操作入口）
  String? lastQuickTunnelId;

  TunnelService({required this.binaries, required this.logs});

  // ---------- 查询接口 ----------
  List<TunnelConfig> get all =>
      _configs.values.toList()..sort((a, b) => b.createdAt - a.createdAt);

  List<TunnelConfig> get running => all
      .where((c) => _runtimes[c.id]?.status == TunnelStatus.running)
      .toList();

  int get runningCount => running.length;

  TunnelConfig? configOf(String id) => _configs[id];
  TunnelRuntime? runtimeOf(String id) => _runtimes[id];

  /// 流量时序采样（每 5s 一点，用于流量曲线展示）
  List<TrafficPoint> trafficSeries(String id) =>
      List.unmodifiable(_trafficSeries[id] ?? const []);

  TunnelStatus statusOf(String id) => _runtimes[id]?.status ?? TunnelStatus.stopped;

  String? publicUrlOf(String id) {
    final rt = _runtimes[id];
    if (rt?.publicUrl != null && rt!.publicUrl!.isNotEmpty) return rt.publicUrl;
    return _configs[id]?.publicHost;
  }

  String get publicUrlSummary {
    final urls = running
        .map((c) => publicUrlOf(c.id))
        .whereType<String>()
        .where((u) => u.isNotEmpty)
        .toList();
    return urls.isEmpty ? '暂无' : urls.join('\n');
  }

  // ---------- 命令组装（技术文档 3.1 通用启动参数规则） ----------
  List<String> buildRunArgs(TunnelConfig c, int metricsPort) {
    if (c.mode == TunnelMode.quick) {
      // 临时隧道：cloudflared tunnel --url 协议://IP:端口
      // cloudflared 快速隧道 origin 仅接受 http/https：
      // WebSocket 服务本质是 HTTP 服务器（协议升级），故统一用 http scheme
      final url = '${c.protocol.isWeb ? 'http' : 'tcp'}://${c.localHost}:${c.localPort}';
      return [
        'tunnel',
        '--url',
        url,
        '--no-autoupdate',
        '--metrics',
        '127.0.0.1:$metricsPort',
      ];
    }
    if (c.isNamedTokenMode) {
      // 远程管理模式：ingress 规则由 Cloudflare 控制台配置
      // 注意：--no-autoupdate 是 tunnel 命令级选项，必须放在 run 子命令之前
      return ['tunnel', '--no-autoupdate', 'run', '--token', c.tunnelToken!];
    }
    // 固定命名隧道：使用 ingress 配置文件而不是 --url。
    // --url 简写仅接受 http/https origin（ws/tcp 会打印 usage 并退出），
    // 而 ingress 的 service 原生支持 http/https/ws/wss/tcp 全协议。
    // 注意：新版内核将 --no-autoupdate/--config/--metrics 定义为 tunnel 命令级选项，
    // 放在 run 之后会报 "flag provided but not defined" 并打印 usage 退出。
    return [
      'tunnel',
      '--no-autoupdate',
      '--config',
      _writeIngressConfig(c),
      '--metrics',
      '127.0.0.1:$metricsPort',
      'run',
      c.tunnelUuid ?? c.name,
    ];
  }

  /// 生成命名隧道 ingress 配置文件（保存到系统临时目录，每次启动重建），返回文件路径。
  /// 凭证文件由 `cloudflared tunnel create` 落盘于 `~/.cloudflared/{uuid}.json`，可省略。
  String _writeIngressConfig(TunnelConfig c) {
    final dir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}cloudtunnelx-ingress');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final key = c.tunnelUuid ?? c.name;
    final host = (c.subdomain ?? '').trim();
    final service = '${c.protocol.scheme}://${c.localHost}:${c.localPort}';
    // hostname 为 *（未绑定子域名）时不能再追加兜底规则，
    // 新版内核会校验报错「Rule matching '*' ... rules which follow it will never be triggered」，
    // 此时直接作为唯一的兜底规则即可。
    final rules = host.isEmpty
        ? '  - service: $service\n'
        : '  - hostname: $host\n    service: $service\n  - service: http_status:404\n';
    final file = File('${dir.path}${Platform.pathSeparator}$key.yml');
    file.writeAsStringSync('tunnel: $key\ningress:\n$rules');
    return file.path;
  }

  Future<int> _allocMetricsPort() async {
    for (var p = 24301; p < 24399; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {}
    }
    return 24300;
  }

  // ---------- 生命周期 ----------
  Future<void> start(TunnelConfig c) async {
    if (statusOf(c.id) == TunnelStatus.running ||
        statusOf(c.id) == TunnelStatus.starting) {
      return;
    }
    // 启动前总是重新解析内核：main() 里的 resolveBinary 是异步的，首次启动时
    // binaryPath 可能尚未赋值，直接用缓存会误报「未找到内核」（Android 上还
    // 依赖平台通道返回 nativeLibraryDir，竞态窗口更大）。
    final binary = await binaries.resolveBinary();
    if (binary == null) {
      logs.log(
          tunnelId: c.id,
          tunnelName: c.name,
          protocol: c.protocol,
          level: LogLevel.error,
          message: Platform.isAndroid
              ? '未找到内置 cloudflared 内核：请确认 APK 已包含 jniLibs/arm64-v8a/libcloudflared.so（arm64 真机；x86 模拟器不支持），并到「设置」页点「重新检测」'
              : '未找到 cloudflared 内核，请到「设置」页一键下载或导入内核');
      return;
    }

    _configs[c.id] = c;
    _userStop[c.id] = false;
    _retrySchedule[c.id] = [3000, 8000, 15000];
    _upsertRuntime(c.id, (rt) {
      rt.status = TunnelStatus.starting;
      rt.lastError = null;
      rt.accessHint = null;
    });

    final metricsPort = await _allocMetricsPort();
    _metricPorts[c.id] = metricsPort;

    try {
      final env = Map<String, String>.from(Platform.environment)
        ..['NO_COLOR'] = '1';
      if (Platform.isAndroid) {
        // Android 没有系统证书路径，注入内置 Mozilla CA 证书包，
        // 否则内核连 trycloudflare.com / Cloudflare API 时 TLS 报
        // "certificate signed by unknown authority"
        env['SSL_CERT_FILE'] = await binaries.ensureCaBundle();
      }
      final p = await Process.start(
        binary,
        buildRunArgs(c, metricsPort),
        runInShell: false,
        environment: env,
      );
      _processes[c.id] = p;

      p.stdout
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .listen((line) => _onKernelLine(c, line));
      p.stderr
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .listen((line) => _onKernelLine(c, line));

      p.exitCode.then((code) => _onProcessExit(c, code));

      // 标记启动成功：进入 running 并启动 metrics 轮询
      Timer(const Duration(seconds: 4), () {
        if (_processes[c.id] == p &&
            _runtimes[c.id]?.status == TunnelStatus.starting) {
          _upsertRuntime(c.id, (rt) {
            rt.status = TunnelStatus.running;
            rt.startedAt = DateTime.now();
            if (c.mode == TunnelMode.named && c.protocol == ProtocolType.tcp) {
              rt.accessHint = _accessHint(c);
            }
          });
          _startMetricsPolling(c.id);
        }
      });
    } catch (e) {
      _upsertRuntime(c.id, (rt) {
        rt.status = TunnelStatus.error;
        rt.lastError = e.toString();
      });
      logs.log(
          tunnelId: c.id,
          tunnelName: c.name,
          protocol: c.protocol,
          level: LogLevel.error,
          message: '启动失败: $e',
          fixHint: '请检查内核是否完整（设置页重新下载），或本地端口是否被占用。');
    }
  }

  String _accessHint(TunnelConfig c) {
    final host = c.subdomain ?? '<隧道域名>';
    return 'cloudflared access tcp --hostname $host --url 127.0.0.1:${c.localPort}';
  }

  void _onKernelLine(TunnelConfig c, String line) {
    // 临时隧道自动分配 trycloudflare 公网域名（需求 3.2.1）
    final m = RegExp(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com').firstMatch(line);
    if (m != null) {
      final url = m.group(0)!;
      _upsertRuntime(c.id, (rt) {
        rt.publicUrl = url;
        rt.status = TunnelStatus.running;
        rt.startedAt ??= DateTime.now();
        if (c.protocol == ProtocolType.tcp) {
          rt.accessHint =
              'cloudflared access tcp --hostname ${url.replaceFirst('https://', '')} --url 127.0.0.1:${c.localPort}';
        }
      });
      logs.log(
          tunnelId: c.id,
          tunnelName: c.name,
          protocol: c.protocol,
          level: LogLevel.success,
          message: '临时公网地址已生成: $url');
    }
    logs.parseKernelLine(
        tunnelId: c.id, tunnelName: c.name, protocol: c.protocol, rawLine: line);
    if (RegExp(r'ERROR|FATAL', caseSensitive: false).hasMatch(line)) {
      _upsertRuntime(c.id, (rt) => rt.lastError = line);
    }
  }

  Future<void> stop(String id) async {
    _userStop[id] = true;
    _metricTimers[id]?.cancel();
    _metricTimers[id] = null;
    _trafficSeries.remove(id);
    _prevBytes.remove(id);
    final p = _processes.remove(id);
    if (p != null) {
      try {
        p.kill(ProcessSignal.sigterm);
        final exited = await p.exitCode
            .timeout(const Duration(seconds: 5), onTimeout: () => -1);
        if (exited == -1) p.kill(ProcessSignal.sigkill);
      } catch (_) {
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    _upsertRuntime(id, (rt) {
      rt.status = TunnelStatus.stopped;
      rt.startedAt = null;
      // 停止后旧链接失效，清空避免页面继续展示（临时隧道尤其明显）
      rt.publicUrl = null;
    });
  }

  void _onProcessExit(TunnelConfig c, int code) {
    _processes.remove(c.id);
    _metricTimers[c.id]?.cancel();
    _metricTimers[c.id] = null;

    if (_userStop[c.id] == true) {
      _upsertRuntime(c.id, (rt) {
        rt.status = TunnelStatus.stopped;
        rt.publicUrl = null; // 用户主动停止后旧链接失效
      });
      return;
    }

    // 断线重连：3s/8s/15s 阶梯式重试（技术文档第 8 章）
    final schedule = _retrySchedule[c.id];
    if (schedule != null && schedule.isNotEmpty) {
      final delay = schedule.removeAt(0);
      _upsertRuntime(c.id, (rt) {
        rt.status = TunnelStatus.reconnecting;
        rt.lastError = '进程退出(code=$code)，${delay}ms 后自动重连';
        rt.publicUrl = null; // 断开期间旧链接失效，重连成功后再填
      });
      logs.log(
          tunnelId: c.id,
          tunnelName: c.name,
          protocol: c.protocol,
          level: LogLevel.warn,
          message: '隧道断开(code=$code)，$delay 毫秒后自动重连',
          fixHint: '网络波动后程序将自动恢复穿透服务，无需手动处理。');
      Timer(Duration(milliseconds: delay), () async {
        final cfg = _configs[c.id];
        if (cfg != null && _userStop[c.id] != true) {
          await start(cfg);
        }
      });
      return;
    }

    _upsertRuntime(c.id, (rt) {
      rt.status = TunnelStatus.error;
      rt.lastError ??= '进程异常退出(code=$code)';
      rt.startedAt = null;
      rt.publicUrl = null; // 异常退出后旧链接失效
    });
  }

  // ---------- 固定隧道管理（需求 3.2.2） ----------
  /// `cloudflared tunnel create <name>` → 解析 UUID
  Future<String> createNamedTunnel(String name) async {
    final binary = binaries.binaryPath;
    if (binary == null) throw StateError('未找到 cloudflared 内核');
    final res = await Process.run(binary, ['tunnel', 'create', name],
        runInShell: Platform.isWindows);
    final out = (res.stdout.toString() + res.stderr.toString()).trim();
    if (res.exitCode != 0) throw StateError(out);
    final m = RegExp(r'id\s+([0-9a-fA-F-]{36})').firstMatch(out) ??
        RegExp(r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
            .firstMatch(out);
    if (m == null) throw StateError('创建成功但未解析到隧道 ID:\n$out');
    return m.group(1)!;
  }

  /// `cloudflared tunnel route dns <uuid> <subdomain>`
  Future<void> routeDns(String uuid, String subdomain) async {
    final binary = binaries.binaryPath;
    if (binary == null) throw StateError('未找到 cloudflared 内核');
    final res = await Process.run(binary, ['tunnel', 'route', 'dns', uuid, subdomain],
        runInShell: Platform.isWindows);
    if (res.exitCode != 0) {
      throw StateError((res.stderr.toString() + res.stdout.toString()).trim());
    }
  }

  Future<void> deleteNamedTunnel(TunnelConfig c) async {
    await stop(c.id);
    if (c.tunnelUuid != null) {
      final binary = binaries.binaryPath;
      if (binary != null) {
        try {
          await Process.run(
              binary, ['tunnel', 'delete', '-f', c.tunnelUuid!],
              runInShell: Platform.isWindows);
        } catch (_) {}
      }
    }
    _configs.remove(c.id);
    _runtimes.remove(c.id);
    notifyListeners();
  }

  /// 进行中的浏览器授权进程（从输出流解析授权 URL）
  Process? _loginProcess;
  String? _loginUrl;

  /// 最近一次登录授权链接（供页面兜底展示/复制）
  String? get loginUrl => _loginUrl;

  /// `cloudflared tunnel login`（浏览器授权，等待 cert.pem 落盘）
  /// 不依赖内核自动打开浏览器：桌面端 detached 启动时经常无反应且输出被丢弃；
  /// 统一改为内嵌运行并从输出流解析授权 URL，再用系统浏览器打开（否则界面无任何反应）。
  /// 返回 (授权URL, 浏览器是否已打开)：两者皆可空，调用方据此兜底提示，避免静默失败。
  Future<(String?, bool)> startLogin() async {
    final binary = binaries.binaryPath;
    if (binary == null) throw StateError('未找到 cloudflared 内核');
    // 已有登录流程进行中：返回其 URL 与打开结果，避免重复启动进程
    if (_loginProcess != null) {
      return (_loginUrl, true);
    }
    final process = await Process.start(
      binary,
      ['tunnel', 'login'],
      // Android 无系统证书路径：注入内置 Mozilla CA，否则登录后获取凭证报证书错误
      environment: Platform.isAndroid
          ? {...Platform.environment, 'SSL_CERT_FILE': await binaries.ensureCaBundle()}
          : null,
    );
    _loginProcess = process;
    // 累积输出再匹配：授权 URL 可能被拆到多个 chunk，逐块匹配会漏掉
    var buf = '';
    final result = Completer<(String?, bool)>();
    void onData(String chunk) {
      buf += chunk;
      final m = RegExp(
              r'https://dash\.cloudflare\.com/argotunnel\?callback=[^\s]+')
          .firstMatch(buf);
      if (m != null && !result.isCompleted) {
        final url = m.group(0)!;
        _loginUrl = url;
        // 打开授权页；用户完成授权后内核自动写 ~/.cloudflared/cert.pem 并退出
        _openLoginUrl(url).then((ok) {
          if (!result.isCompleted) result.complete((url, ok));
        });
      }
    }

    process.stdout.transform(utf8.decoder).listen(onData);
    process.stderr.transform(utf8.decoder).listen(onData);
    process.exitCode.then((_) {
      if (identical(_loginProcess, process)) _loginProcess = null;
      // 进程在输出出完整 URL 前退出（如排队失败/网络异常）：
      // 稍等流数据排空后提前收尾，避免页面干等 20 秒超时
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!result.isCompleted) result.complete((_loginUrl, false));
      });
    });
    try {
      return await result.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      return (_loginUrl, false);
    }
  }

  /// 用系统浏览器打开授权页；失败返回 false（由页面兜底展示链接）
  Future<bool> _openLoginUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 终止进行中的浏览器授权进程（授权完成/取消后调用，释放后台进程）
  Future<void> stopLogin() async {
    final p = _loginProcess;
    _loginProcess = null;
    if (p != null) {
      try {
        p.kill();
      } catch (_) {}
    }
  }

  // ---------- metrics 流量统计（需求 3.1 在线时长/流量简要统计） ----------
  void _startMetricsPolling(String id) {
    _metricTimers[id]?.cancel();
    _metricTimers[id] = Timer.periodic(const Duration(seconds: 5), (_) async {
      final port = _metricPorts[id];
      if (port == null || statusOf(id) != TunnelStatus.running) return;
      try {
        final res = await http
            .get(Uri.parse('http://127.0.0.1:$port/metrics'))
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          _parseMetrics(id, res.body);
          // 首次轮询成功记一次摘要日志：若解析结果与预期不符（如计数为 0），
          // 直接看该条日志即可判断是内核口径还是解析问题
          if (_metricsLogged.add(id)) {
            final c = _configs[id];
            logs.log(
                tunnelId: id,
                tunnelName: c?.name ?? '',
                protocol: c?.protocol,
                level: LogLevel.info,
                message: 'metrics 接口正常（${res.body.split('\n').length} 行指标）');
          }
        }
      } catch (e) {
        // 静默失败会让人以为统计功能故障：每个隧道只告警一次。
        // 常见原因：Android 未允许明文流量（usesCleartextTraffic）或内核 metrics 未监听。
        if (_metricsWarned.add(id)) {
          final c = _configs[id];
          logs.log(
              tunnelId: id,
              tunnelName: c?.name ?? '',
              protocol: c?.protocol,
              level: LogLevel.warn,
              message: 'metrics 统计接口不可达（流量曲线/统计将不可用）：$e');
        }
      }
    });
  }

  void _parseMetrics(String id, String body) {
    var requests = 0;
    var bytes = 0;
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      // 用 num 解析：Prometheus 浮点值（如内存类指标 1.2e+06）用 int.tryParse 会失败
      final value = num.tryParse(parts.last);
      if (value == null) continue;
      final name = parts.first.split('{').first;
      // 请求数：只认累计计数器 total_requests（新版/旧版通用），
      // 避免 concurrent/per_tunnel 等瞬时量把请求数翻倍
      if (name.contains('total_requests')) requests += value.toInt();
      // 流量字节：仅累计隧道实际传输字节（QUIC client / 旧版 muxer 压缩字节），
      // 排除 go_memstats_*、process_* 等内存字节，否则"流量"会虚高畸变
      if (name.contains('bytes') &&
          !name.contains('compressed') &&
          !name.startsWith('go_') &&
          !name.startsWith('process_')) {
        bytes += value.toInt();
      }
    }
    if (requests > 0 || bytes > 0) {
      _upsertRuntime(id, (rt) {
        rt.requestCount = requests;
        rt.bytesCount = bytes;
      });
    }
    // 流量时序采样：记录本周期增量字节数（计数器重置时钳制为 0）
    final prev = _prevBytes[id] ?? bytes;
    final delta = bytes - prev;
    _prevBytes[id] = bytes;
    final series = _trafficSeries.putIfAbsent(id, () => []);
    series.add(TrafficPoint(
        time: DateTime.now(), bytes: delta < 0 ? 0 : delta));
    if (series.length > _maxSeriesPoints) {
      series.removeRange(0, series.length - _maxSeriesPoints);
    }
  }

  // ---------- 工具 ----------
  void _upsertRuntime(String id, void Function(TunnelRuntime) fn) {
    final rt = _runtimes.putIfAbsent(id, () => TunnelRuntime(id: id));
    fn(rt);
    notifyListeners();
  }

  void registerConfig(TunnelConfig c) {
    _configs[c.id] = c;
    notifyListeners();
  }

  void removeConfig(String id) {
    _configs.remove(id);
    _runtimes.remove(id);
    _metricTimers[id]?.cancel();
    _trafficSeries.remove(id);
    _prevBytes.remove(id);
    notifyListeners();
  }

  Future<void> stopAll() async {
    for (final id in List.of(_processes.keys)) {
      await stop(id);
    }
  }

  @override
  void dispose() {
    for (final t in _metricTimers.values) {
      t?.cancel();
    }
    for (final p in _processes.values) {
      try {
        p.kill();
      } catch (_) {}
    }
    super.dispose();
  }
}
