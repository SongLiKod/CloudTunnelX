import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/protocol_type.dart';
import '../../core/models/tunnel_config.dart';
import '../../core/models/tunnel_status.dart';
import '../../core/services/app_controller.dart';
import '../../core/services/validation_service.dart';
import '../widgets/common.dart';

/// 临时穿透（需求 3.2.1）：一键启动/停止、复制临时访问链接，快速测试
class QuickTunnelPage extends StatefulWidget {
  const QuickTunnelPage({super.key});

  @override
  State<QuickTunnelPage> createState() => _QuickTunnelPageState();
}

class _QuickTunnelPageState extends State<QuickTunnelPage> {
  final _hostCtrl = TextEditingController(text: '127.0.0.1');
  final _portCtrl = TextEditingController(text: '8080');
  ProtocolType _protocol = ProtocolType.http;
  bool _busy = false;
  List<ValidationIssue> _issues = [];

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final port = int.tryParse(_portCtrl.text.trim());
    setState(() => _issues = []);
    if (port == null) {
      setState(() => _issues = [const ValidationIssue('端口必须为数字（1~65535）')]);
      return;
    }
    setState(() => _busy = true);
    final app = context.read<AppController>();
    final vr = await app.startQuickTunnel(
      protocol: _protocol,
      localHost: _hostCtrl.text.trim(),
      localPort: port,
    );
    if (mounted) setState(() { _issues = vr.issues; _busy = false; });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final quickList = app.tunnels.all
        .where((c) => c.mode == TunnelMode.quick)
        .toList();
    final latest = quickList.isNotEmpty ? quickList.first : null;
    final latestRt = latest == null ? null : app.tunnels.runtimeOf(latest.id);
    final latestStatus = latest == null ? null : app.tunnels.statusOf(latest.id);
    final url = latest == null ? null : app.tunnels.publicUrlOf(latest.id);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('临时穿透 · 快速测试',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('无需自有域名，HTTP/HTTPS/WebSocket 自动生成 Cloudflare 临时域名；TCP 穿透请使用固定隧道并配合 Access 命令接入',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<ProtocolType>(
                    initialValue: _protocol,
                    decoration: const InputDecoration(
                        labelText: '协议类型', prefixIcon: Icon(Icons.dns_rounded)),
                    items: ProtocolType.values
                        .map((p) => DropdownMenuItem(
                            value: p,
                            enabled: p != ProtocolType.tcp,
                            child: Text(
                                '${p.label} · ${p.desc}',
                                style: TextStyle(
                                    fontSize: 14,
                                    color: p == ProtocolType.tcp
                                        ? Theme.of(context).disabledColor
                                        : null))))
                        .toList(),
                    onChanged: (v) => setState(() => _protocol = v!),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _hostCtrl,
                    decoration: const InputDecoration(
                        labelText: '本地 IP（默认 127.0.0.1）',
                        prefixIcon: Icon(Icons.computer_rounded)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: '本地端口',
                        prefixIcon: const Icon(Icons.settings_ethernet_rounded),
                        helperText: _protocolHint),
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              Row(children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _start,
                  icon: const Icon(Icons.rocket_launch_rounded, size: 18),
                  label: const Text('一键启动'),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: (latestStatus == TunnelStatus.running ||
                          latestStatus == TunnelStatus.starting ||
                          latestStatus == TunnelStatus.reconnecting)
                      ? () => app.stopTunnel(latest!.id)
                      : null,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('一键停止'),
                ),
                const Spacer(),
                if (latestStatus == TunnelStatus.running ||
                    latestStatus == TunnelStatus.starting)
                  StatusChip(status: latestStatus!),
              ]),
              for (final i in _issues)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(children: [
                    Icon(Icons.error_outline_rounded,
                        size: 16, color: Colors.red.shade300),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(i.message,
                            style:
                                TextStyle(fontSize: 12.5, color: Colors.red.shade200))),
                  ]),
                ),
              if (_busy) const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 3),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        if (latest != null && url != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.celebration_rounded,
                      color: Colors.green.shade300, size: 20),
                  const SizedBox(width: 8),
                  Text('公网访问地址已生成',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10)),
                  child: Row(children: [
                    Expanded(
                        child: SelectableText(url,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 15))),
                    OpenUrlButton(url: url),
                    QrButton(value: ensureScheme(url)),
                    CopyButton(value: url, tooltip: '复制访问链接'),
                  ]),
                ),
                if (latestRt?.accessHint != null) ...[
                  const SizedBox(height: 10),
                  Text('TCP 服务请在客户端机器上执行以下命令接入：',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10)),
                    child: Row(children: [
                      Expanded(
                          child: SelectableText(latestRt!.accessHint!,
                              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13))),
                      QrButton(value: latestRt.accessHint!, tooltip: '接入命令二维码'),
                      CopyButton(value: latestRt.accessHint!, tooltip: '复制接入命令'),
                    ]),
                  ),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (quickList.isNotEmpty) ...[
          Text('本次会话临时隧道（${quickList.length}）',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...quickList.map((c) {
            final st = app.tunnels.statusOf(c.id);
            final u = app.tunnels.publicUrlOf(c.id);
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: ProtocolChip(protocol: c.protocol),
                title: Text('${c.localHost}:${c.localPort}',
                    style: const TextStyle(fontSize: 14)),
                subtitle: u != null ? Text(u, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  StatusChip(status: st),
                  if (u != null) CopyButton(value: u),
                  IconButton(
                      tooltip: '停止',
                      icon: const Icon(Icons.stop_circle_outlined, size: 20),
                      onPressed: (st == TunnelStatus.running ||
                              st == TunnelStatus.starting ||
                              st == TunnelStatus.reconnecting)
                          ? () => app.stopTunnel(c.id)
                          : null),
                  IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                                  title: const Text('删除临时隧道'),
                                  content: Text(
                                      '确定删除该临时隧道（${c.localHost}:${c.localPort}）？将停止进程并移除本地配置。'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('取消')),
                                    FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('删除')),
                                  ],
                                ));
                        if (ok == true && context.mounted) {
                          await app.deleteTunnel(c);
                        }
                      }),
                ]),
              ),
            );
          }),
        ],
      ],
    );
  }

  String get _protocolHint => switch (_protocol) {
        ProtocolType.http || ProtocolType.https => '网页常用 80/8080/3000',
        ProtocolType.websocket => 'WS 服务端口，如 8765',
        ProtocolType.tcp => '如 SSH 22 / RDP 3389 / MySQL 3306',
      };
}
