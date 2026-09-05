import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/protocol_type.dart';
import '../../core/models/tunnel_config.dart';
import '../../core/models/tunnel_status.dart';
import '../../core/services/app_controller.dart';
import '../../core/services/validation_service.dart';
import '../widgets/common.dart';

/// 固定穿透（需求 3.2.2）：命名隧道创建、域名/端口路由绑定、启停、删除、修改配置
class TunnelsPage extends StatelessWidget {
  const TunnelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final named = app.tunnels.all
        .where((c) => c.mode == TunnelMode.named)
        .toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context),
        icon: const Icon(Icons.add_link_rounded),
        label: const Text('创建隧道'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('固定穿透 · 正式使用',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('绑定自有域名或固定入口，创建永久命名隧道；首次使用请先到「设置」完成 Cloudflare 登录授权',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          if (named.isEmpty) const _EmptyNamed(),
          ...named.map((c) => _NamedCard(config: c)),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context) {
    showDialog(context: context, builder: (_) => const _TunnelEditDialog());
  }
}

class _EmptyNamed extends StatelessWidget {
  const _EmptyNamed();

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(children: [
            Icon(Icons.dns_rounded,
                size: 44, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            const Text('还没有固定隧道'),
            const SizedBox(height: 4),
            Text('点击右下角「创建隧道」，自定义名称 → 选择协议 → 绑定域名 → 填写本地服务地址',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}

class _NamedCard extends StatelessWidget {
  final TunnelConfig config;
  const _NamedCard({required this.config});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final c = config;
    final status = app.tunnels.statusOf(c.id);
    final rt = app.tunnels.runtimeOf(c.id);
    final isBusy = status == TunnelStatus.running ||
        status == TunnelStatus.starting ||
        status == TunnelStatus.reconnecting;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ProtocolChip(protocol: c.protocol),
            const SizedBox(width: 10),
            Expanded(
              child: Text(c.name,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            StatusChip(status: status),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 16, runSpacing: 6, children: [
            _kv('绑定域名', c.subdomain ?? '（Token 远程管理）'),
            _kv('本地服务', '${c.localHost}:${c.localPort}'),
            _kv('管理方式', c.isNamedTokenMode ? 'Token' : '本地授权'),
            if (c.autoRestore) _kv('开机恢复', '是'),
          ]),
          if (rt?.accessHint != null) ...[
            const SizedBox(height: 8),
            Text('客户端接入命令（在访问端执行）：',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Expanded(
                    child: SelectableText(rt!.accessHint!,
                        style: const TextStyle(
                            fontFamily: 'Consolas', fontSize: 12.5))),
                CopyButton(value: rt.accessHint!, tooltip: '复制接入命令'),
              ]),
            ),
          ],
          if (status == TunnelStatus.error && rt != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.report_rounded, size: 16, color: Colors.red.shade300),
              const SizedBox(width: 6),
              Expanded(
                child: Text(rt.lastError ?? '隧道异常',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: Colors.red.shade200)),
              ),
            ]),
          ],
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (c.tunnelUuid != null && app.cf.configured)
              TextButton.icon(
                onPressed: () async {
                  final n = await app.tunnelConnections(c.tunnelUuid!);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(n == null
                        ? '查询边缘连接失败，请检查 API Token 权限或网络'
                        : '隧道「${c.name}」当前边缘连接数：$n'),
                    duration: const Duration(seconds: 3),
                  ));
                },
                icon: const Icon(Icons.cloud_done_outlined, size: 16),
                label: const Text('边缘连接'),
              ),
            TextButton.icon(
              onPressed: () => _showEditDialog(context, c),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('修改'),
            ),
            TextButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                          title: const Text('删除隧道'),
                          content: Text(
                              '确定删除隧道「${c.name}」？\n将同时移除本地配置并注销 Cloudflare 命名隧道。'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消')),
                            FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('删除')),
                          ],
                        ));
                if (ok == true && context.mounted) await app.deleteTunnel(c);
              },
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: const Text('删除'),
            ),
            const SizedBox(width: 8),
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

  void _showEditDialog(BuildContext context, TunnelConfig c) {
    showDialog(context: context, builder: (_) => _TunnelEditDialog(existing: c));
  }
}

/// 创建 / 修改 隧道弹窗
class _TunnelEditDialog extends StatefulWidget {
  final TunnelConfig? existing;
  const _TunnelEditDialog({this.existing});

  @override
  State<_TunnelEditDialog> createState() => _TunnelEditDialogState();
}

class _TunnelEditDialogState extends State<_TunnelEditDialog> {
  late bool _tokenMode = widget.existing?.isNamedTokenMode ?? false;
  late ProtocolType _protocol = widget.existing?.protocol ?? ProtocolType.http;
  late final _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
  late final _hostCtrl =
      TextEditingController(text: widget.existing?.localHost ?? '127.0.0.1');
  late final _portCtrl = TextEditingController(
      text: widget.existing?.localPort.toString() ?? '8080');
  late final _subCtrl =
      TextEditingController(text: widget.existing?.subdomain ?? '');
  late final _tokenCtrl =
      TextEditingController(text: widget.existing?.tunnelToken ?? '');
  late bool _autoRestore = widget.existing?.autoRestore ?? true;
  bool _skipDnsCheck = false;
  bool _creating = false;
  String? _stepText;
  List<ValidationIssue> _issues = [];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _subCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final app = context.read<AppController>();
    final port = int.tryParse(_portCtrl.text.trim());
    if (port == null) {
      setState(() => _issues = [const ValidationIssue('端口必须为数字（1~65535）')]);
      return;
    }

    // 修改模式
    final ex = widget.existing;
    if (ex != null) {
      await app.updateTunnel(ex,
          name: _nameCtrl.text.trim(),
          localHost: _hostCtrl.text.trim(),
          localPort: port,
          autoRestore: _autoRestore);
      if (mounted) Navigator.pop(context);
      return;
    }

    // 创建模式：依次执行 校验→创建→路由绑定→启动（需求 4.2 业务流程）
    setState(() {
      _creating = true;
      _issues = [];
      _stepText = '正在校验配置…';
    });
    final (created, vr) = await app.createNamedTunnel(
      name: _nameCtrl.text,
      protocol: _protocol,
      localHost: _hostCtrl.text,
      localPort: port,
      subdomain: _subCtrl.text,
      token: _tokenCtrl.text,
      tokenMode: _tokenMode,
      autoRestore: _autoRestore,
      skipDnsCheck: _skipDnsCheck,
    );
    if (!mounted) return;
    if (created == null) {
      setState(() {
        _creating = false;
        _stepText = null;
        _issues = vr.issues;
      });
      return;
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? '创建固定隧道' : '修改隧道配置'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (isNew)
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('本地授权'), icon: Icon(Icons.key_rounded, size: 16)),
                  ButtonSegment(value: true, label: Text('Token 管理'), icon: Icon(Icons.badge_outlined, size: 16)),
                ],
                selected: {_tokenMode},
                onSelectionChanged: (s) => setState(() => _tokenMode = s.first),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              enabled: isNew,
              decoration: const InputDecoration(
                  labelText: '隧道名称（用于区分多隧道服务）',
                  prefixIcon: Icon(Icons.label_outline_rounded)),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<ProtocolType>(
              initialValue: _protocol,
              decoration: const InputDecoration(
                  labelText: '协议类型', prefixIcon: Icon(Icons.dns_rounded)),
              items: ProtocolType.values
                  .map((p) => DropdownMenuItem(
                      value: p,
                      child: Text('${p.label} · ${p.desc}',
                          style: const TextStyle(fontSize: 14))))
                  .toList(),
              onChanged: isNew ? (v) => setState(() => _protocol = v!) : null,
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _hostCtrl,
                  decoration: const InputDecoration(
                      labelText: '本地服务 IP', prefixIcon: Icon(Icons.computer_rounded)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _portCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '本地端口', prefixIcon: Icon(Icons.settings_ethernet_rounded)),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            if (_tokenMode) ...[
              TextField(
                controller: _tokenCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: 'Cloudflare Tunnel Token（控制台创建后粘贴）',
                    prefixIcon: Icon(Icons.badge_outlined)),
              ),
            ] else ...[
              TextField(
                controller: _subCtrl,
                decoration: InputDecoration(
                    labelText: _protocol.isWeb
                        ? '绑定子域名（如 app.example.com）'
                        : '入口子域名（客户端经 Access 接入）',
                    prefixIcon: const Icon(Icons.link_rounded)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('跳过 DNS 托管校验', style: TextStyle(fontSize: 14)),
                subtitle: const Text('域名刚迁移或离线校验失败时可临时跳过',
                    style: TextStyle(fontSize: 12)),
                value: _skipDnsCheck,
                onChanged: (v) => setState(() => _skipDnsCheck = v),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('开机自启后自动恢复该隧道', style: TextStyle(fontSize: 14)),
              value: _autoRestore,
              onChanged: (v) => setState(() => _autoRestore = v),
            ),
            for (final i in _issues)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.error_outline_rounded,
                      size: 16, color: Colors.red.shade300),
                  const SizedBox(width: 6),
                  Expanded(
                      child: SelectableText(i.message,
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.red.shade200))),
                ]),
              ),
            if (_creating) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 3),
              const SizedBox(height: 6),
              Text(_stepText ?? '执行中…',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _creating ? null : () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
            onPressed: _creating ? null : _submit,
            child: Text(isNew ? '创建并启动' : '保存')),
      ],
    );
  }
}
