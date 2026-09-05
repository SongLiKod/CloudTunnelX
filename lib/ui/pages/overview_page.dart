import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/tunnel_config.dart';
import '../../core/models/tunnel_status.dart';
import '../../core/services/app_controller.dart';
import '../widgets/common.dart';

/// 首页总览（需求 3.1）：状态数据 / 穿透配置 / 公网地址 / 在线时长与流量 / 异常提醒
class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    // 动态排序：运行中/启动中/重连中的隧道置顶，停止/异常下沉；同组按创建时间倒序
    final all = [...app.tunnels.all]..sort((a, b) {
        final ra = _activeRank(app.tunnels.statusOf(a.id));
        final rb = _activeRank(app.tunnels.statusOf(b.id));
        if (ra != rb) return ra.compareTo(rb);
        return b.createdAt.compareTo(a.createdAt);
      });
    final runningList =
        all.where((c) => app.tunnels.statusOf(c.id) == TunnelStatus.running);

    var bytes = 0;
    var requests = 0;
    for (final c in all) {
      final rt = app.tunnels.runtimeOf(c.id);
      bytes += rt?.bytesCount ?? 0;
      requests += rt?.requestCount ?? 0;
    }
    final totalUptime = runningList.fold<int>(
        0,
        (acc, c) =>
            acc + (app.tunnels.runtimeOf(c.id)?.uptime?.inSeconds ?? 0));

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('服务总览',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 900 ? 4 : 2;
          const gap = 12.0;
          final w = (c.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              SizedBox(
                  width: w,
                  child: StatCard(
                      title: '运行中隧道',
                      value: '${runningList.length} / ${all.length}',
                      icon: Icons.link_rounded)),
              SizedBox(
                  width: w,
                  child: StatCard(
                      title: '累计在线时长',
                      value: _fmtDuration(Duration(seconds: totalUptime)),
                      icon: Icons.schedule_rounded)),
              SizedBox(
                  width: w,
                  child: StatCard(
                      title: '请求数（简要）',
                      value: _fmtCount(requests),
                      icon: Icons.swap_vert_rounded)),
              SizedBox(
                  width: w,
                  child: StatCard(
                      title: '流量（简要）',
                      value: _fmtBytes(bytes),
                      icon: Icons.data_usage_rounded)),
            ],
          );
        }),
        const SizedBox(height: 20),
        if (all.isEmpty) const _EmptyHint(),
        ...all.map((c) => _TunnelCard(config: c)),
      ],
    );
  }

  /// 活跃度排序权重：运行中/启动中/重连中优先置顶
  static int _activeRank(TunnelStatus s) => switch (s) {
        TunnelStatus.running => 0,
        TunnelStatus.starting => 1,
        TunnelStatus.reconnecting => 2,
        _ => 3,
      };

  static String _fmtDuration(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60;
    if (h > 0) return '$h 时 $m 分';
    if (m > 0) return '$m 分 ${d.inSeconds % 60} 秒';
    return '${d.inSeconds} 秒';
  }

  static String _fmtCount(int n) =>
      n >= 10000 ? '${(n / 10000).toStringAsFixed(1)} 万' : '$n';

  static String _fmtBytes(int b) {
    if (b <= 0) return '0 B';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(children: [
            Icon(Icons.cloud_queue_rounded,
                size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text('还没有隧道，去「临时穿透」一键测试，或在「固定穿透」创建正式隧道',
                style: Theme.of(context).textTheme.bodyMedium),
          ]),
        ),
      );
}

class _TunnelCard extends StatelessWidget {
  final TunnelConfig config;
  const _TunnelCard({required this.config});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final c = config;
    final status = app.tunnels.statusOf(c.id);
    final rt = app.tunnels.runtimeOf(c.id);
    final url = app.tunnels.publicUrlOf(c.id);
    final isBusy = status == TunnelStatus.starting ||
        status == TunnelStatus.running ||
        status == TunnelStatus.reconnecting;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ProtocolChip(protocol: c.protocol),
            const SizedBox(width: 10),
            Expanded(
              child: Text(c.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            StatusChip(status: status),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 6, children: [
            _kv('模式', c.mode == TunnelMode.quick ? '临时穿透' : '固定穿透'),
            _kv('本地服务', '${c.localHost}:${c.localPort}'),
            if (c.schedule?.enabled == true)
              _kv('定时启停', c.schedule!.label),
            if (rt?.uptime != null)
              _kv('在线时长', OverviewPage._fmtDuration(rt!.uptime!)),
            if ((rt?.requestCount ?? 0) > 0) _kv('请求数', '${rt!.requestCount}'),
            if ((rt?.bytesCount ?? 0) > 0)
              _kv('流量', '${(rt!.bytesCount / 1024 / 1024).toStringAsFixed(1)} MB'),
          ]),
          if (url != null && url.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Icon(Icons.public_rounded,
                    size: 16, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                    child: SelectableText(url,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                OpenUrlButton(url: url),
                QrButton(value: ensureScheme(url)),
                CopyButton(value: url),
              ]),
            ),
          ],
          if (rt?.accessHint != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.terminal_rounded,
                  size: 16, color: Colors.deepPurple.shade200),
              const SizedBox(width: 8),
              Expanded(
                  child: SelectableText(rt!.accessHint!,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'Consolas',
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant))),
              QrButton(value: rt.accessHint!, tooltip: '接入命令二维码'),
              CopyButton(value: rt.accessHint!, tooltip: '复制客户端接入命令'),
            ]),
          ],
          if (status == TunnelStatus.running) ...[
            Builder(builder: (context) {
              final series = app.tunnels.trafficSeries(c.id);
              if (series.length < 2) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TrafficSparkline(points: series),
              );
            }),
          ],
          if (status == TunnelStatus.error && rt != null) ...[
            const SizedBox(height: 10),
            _ErrorRow(runtime: rt),
          ],
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (isBusy)
              FilledButton.tonalIcon(
                  onPressed: () => app.stopTunnel(c.id),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('停止'))
            else
              FilledButton.icon(
                  onPressed: () => app.startTunnel(c),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('启动')),
          ]),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$k：',
            style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
        Text(v, style: const TextStyle(fontSize: 12.5)),
      ]);
}

class _ErrorRow extends StatelessWidget {
  final dynamic runtime;
  const _ErrorRow({required this.runtime});

  @override
  Widget build(BuildContext context) {
    final logs = context.read<AppController>().logs;
    final err = logs.latestErrorFor(runtime.id);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
      child: Row(children: [
        Icon(Icons.report_rounded, color: Colors.red.shade300, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            err?.message ?? runtime.lastError ?? '隧道异常',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: Colors.red.shade200),
          ),
        ),
        TextButton(
          onPressed: () => showFixDialog(
            context,
            title: '隧道异常提醒',
            cause: err?.message ?? runtime.lastError ?? '未知错误',
            fix: err?.fixHint ?? '请查看「日志」页获取详细信息，或重新校验配置。',
          ),
          child: const Text('查看修复方案'),
        ),
      ]),
    );
  }
}
