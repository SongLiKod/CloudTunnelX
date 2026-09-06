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
    showDialog(context: context, builder: (_) => const TunnelEditDialog());
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
    final url = app.tunnels.publicUrlOf(c.id);
    final accName =
        app.cfAccounts.where((a) => a.id == c.accountId).firstOrNull?.name;
    final sched = c.schedule;
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
            if (accName != null) _kv('所属账号', accName),
            if (sched?.enabled == true) _kv('定时启停', sched!.label),
            if (c.autoRestore) _kv('开机恢复', '是'),
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
                QrButton(value: rt.accessHint!, tooltip: '接入命令二维码'),
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
                  final n =
                      await app.tunnelConnections(c.tunnelUuid!, accountId: c.accountId);
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
    showDialog(context: context, builder: (_) => TunnelEditDialog(existing: c));
  }
}

/// 创建 / 修改 隧道弹窗（域名页「在此域名下创建固定隧道」可预填子域名与账号）
class TunnelEditDialog extends StatefulWidget {
  final TunnelConfig? existing;

  /// 预填绑定子域名（如 example.com，用户补前缀）
  final String? initialSubdomain;

  /// 预填所属 Cloudflare 账号 id
  final String? initialAccountId;

  const TunnelEditDialog(
      {super.key, this.existing, this.initialSubdomain, this.initialAccountId});

  @override
  State<TunnelEditDialog> createState() => _TunnelEditDialogState();
}

class _TunnelEditDialogState extends State<TunnelEditDialog> {
  late bool _tokenMode = widget.existing?.isNamedTokenMode ?? false;
  late ProtocolType _protocol = widget.existing?.protocol ?? ProtocolType.http;
  late final _nameCtrl = TextEditingController(text: widget.existing?.name ?? '');
  late final _hostCtrl =
      TextEditingController(text: widget.existing?.localHost ?? '127.0.0.1');
  late final _portCtrl = TextEditingController(
      text: widget.existing?.localPort.toString() ?? '8080');
  late final _subCtrl = TextEditingController(
      text: widget.existing?.subdomain ?? widget.initialSubdomain ?? '');
  late final _tokenCtrl =
      TextEditingController(text: widget.existing?.tunnelToken ?? '');
  late bool _autoRestore = widget.existing?.autoRestore ?? true;
  late String? _accountId = widget.existing?.accountId ?? widget.initialAccountId;
  late bool _scheduleEnabled = widget.existing?.schedule?.enabled ?? false;
  late String _scheduleStart = widget.existing?.schedule?.start ?? '09:00';
  late String _scheduleEnd = widget.existing?.schedule?.end ?? '18:00';
  late final Set<int> _scheduleDays = {
    ...(widget.existing?.schedule?.weekdays ?? const [1, 2, 3, 4, 5])
  };
  bool _skipDnsCheck = false;
  bool _creating = false;
  bool _generating = false;
  bool _binding = false;
  String? _boundDomain;
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

  /// 解析当前归属账号：未选或账号已删除时回落到首个账号；无任何账号返回 null
  String? _pickAccountId() {
    final accounts = context.read<AppController>().cfAccounts;
    if (accounts.isEmpty) return null;
    if (_accountId != null && accounts.any((a) => a.id == _accountId)) {
      return _accountId;
    }
    return accounts.first.id;
  }

  /// 组装定时计划（关闭定时时保留时段设置但标记 disabled）
  TunSchedule _schedule() => TunSchedule(
        enabled: _scheduleEnabled,
        start: _scheduleStart,
        end: _scheduleEnd,
        weekdays: _scheduleDays.isEmpty
            ? const []
            : _scheduleDays.toList()
                  ..sort(),
      );

  /// 所属账号下拉（未配置任何账号时隐藏）
  Widget _accountPicker(AppController app) {
    final accounts = app.cfAccounts;
    if (accounts.isEmpty) return const SizedBox.shrink();
    return DropdownButtonFormField<String>(
      initialValue: _pickAccountId(),
      decoration: const InputDecoration(
          labelText: '所属 Cloudflare 账号',
          prefixIcon: Icon(Icons.account_circle_rounded),
          helperText: '该隧道的 DNS 校验与 CNAME 路由将落在所选账号下'),
      items: accounts
          .map((a) =>
              DropdownMenuItem(value: a.id, child: Text(a.name)))
          .toList(),
      onChanged: (v) => setState(() => _accountId = v),
    );
  }

  /// 时间选择字段（点击弹出 TimePicker）
  Widget _timeField(String label, String value, ValueChanged<String> onPick) {
    final p = value.split(':');
    return InkWell(
      onTap: () async {
        final t = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(
              hour: int.tryParse(p[0]) ?? 9, minute: int.tryParse(p[1]) ?? 0),
        );
        if (t != null) {
          onPick(
              '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.schedule_rounded),
          suffixIcon: const Icon(Icons.expand_more_rounded),
        ),
        child: Text(value,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  /// 一键生成 Token：用「域名管理」已配置的 Cloudflare API Token 创建
  /// 远程管理隧道并取回运行 Token，实现免 cert.pem / cert 登录。
  /// 需要该 API Token 含「Account › Cloudflare Tunnel › Edit」权限。
  Future<void> _generateToken() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _generating = true;
      _issues = [];
    });
    try {
      final app = context.read<AppController>();
      final accountId = _pickAccountId();
      // 取所选账号的实例：默认账号时直接使用主 cf 实例，多账号时按账号 ID 取
      final svc = accountId == null ? app.cf : await app.serviceFor(accountId);
      if (!svc.configured) {
        setState(() => _issues = const [
          ValidationIssue('未配置所选账号的 Cloudflare API Token：请先在「设置 → Cloudflare API Token」配置（需含 Account › Cloudflare Tunnel › Edit 权限）')
        ]);
        return;
      }
      var name = _nameCtrl.text.trim();
      if (name.isEmpty) {
        name = 'cloudtunnelx-${DateTime.now().millisecondsSinceEpoch}';
      }
      // 隧道名仅允许字母 / 数字 / _ / -，其余字符清洗为连字符
      name = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-');
      final token = await svc.createTunnelToken(name);
      _tokenCtrl.text = token;
      messenger.showSnackBar(SnackBar(
          content: Text('已生成 Token（隧道：$name，远程管理模式），可直接保存并启动隧道')));
    } catch (e) {
      setState(() => _issues = [
        ValidationIssue(
            '生成失败：$e\n提示：若报权限不足，请在 Cloudflare 控制台创建含「Account › Cloudflare Tunnel › Edit」权限的 API Token，再到「域名管理」配置。')
      ]);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _bindDomain() async {
    final messenger = ScaffoldMessenger.of(context);
    final token = _tokenCtrl.text.trim();
    final host = _subCtrl.text.trim();
    if (token.isEmpty) {
      setState(() => _issues = const [
        ValidationIssue('请先粘贴或一键生成 Cloudflare Tunnel Token，再绑定访问域名。')
      ]);
      return;
    }
    if (host.isEmpty) {
      setState(() => _issues = const [
        ValidationIssue('请先填写访问域名（如 app.example.com）。')
      ]);
      return;
    }
    setState(() {
      _binding = true;
      _issues = [];
    });
    try {
      final app = context.read<AppController>();
      final accountId = _pickAccountId();
      // 取所选账号的实例：默认账号时直接使用主 cf 实例，多账号时按账号 ID 取
      final svc = accountId == null ? app.cf : await app.serviceFor(accountId);
      if (!svc.configured) {
        setState(() => _issues = const [
          ValidationIssue('未配置所选账号的 Cloudflare API Token：请先在「设置 → Cloudflare API Token」配置（需含 Account › Cloudflare Tunnel › Edit 与 Zone › DNS › Edit 权限）')
        ]);
        return;
      }
      final zones = await svc.listZones();
      final zone = AppController.bestZoneFor(host, zones);
      if (zone == null) {
        setState(() => _issues = [
          ValidationIssue('访问域名 $host 未托管在所选账号的 Cloudflare 中（未找到匹配 Zone）。请确认域名已在 Cloudflare 托管，或切换下方所属账号。')
        ]);
        return;
      }
      final service =
          '${_protocol.scheme}://${_hostCtrl.text.trim()}:${_portCtrl.text.trim()}';
      await svc.bindTunnelHostname(
        token: token,
        hostname: host,
        service: service,
        zoneId: zone.id,
      );
      setState(() => _boundDomain = host);
      messenger.showSnackBar(SnackBar(
          content: Text('已绑定 DNS 路由：$host → $service，保存并启动隧道后即可访问 https://$host')));
    } catch (e) {
      setState(() => _issues = [
        ValidationIssue(
            '绑定失败：$e\n提示：若报权限不足，请在 Cloudflare 控制台创建含「Account › Cloudflare Tunnel › Edit」和「Zone › DNS › Edit」权限的 API Token。')
      ]);
    } finally {
      if (mounted) setState(() => _binding = false);
    }
  }

  Future<void> _submit() async {
    final app = context.read<AppController>();
    final port = int.tryParse(_portCtrl.text.trim());
    if (port == null) {
      setState(() => _issues = [const ValidationIssue('端口必须为数字（1~65535）')]);
      return;
    }
    final accountId = _pickAccountId();
    final schedule = _schedule();

    // 修改模式
    final ex = widget.existing;
    if (ex != null) {
      await app.updateTunnel(ex,
          name: _nameCtrl.text.trim(),
          localHost: _hostCtrl.text.trim(),
          localPort: port,
          autoRestore: _autoRestore,
          accountId: accountId,
          schedule: schedule);
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
      accountId: accountId,
      schedule: schedule,
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
    final app = context.watch<AppController>();
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
            _accountPicker(app),
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
                    labelText: 'Cloudflare Tunnel Token（控制台创建后粘贴，或点击下方一键生成）',
                    prefixIcon: Icon(Icons.badge_outlined)),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _generating ? null : _generateToken,
                    icon: _generating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_fix_high_rounded, size: 17),
                    label: const Text('一键生成 Token（无需登录）'),
                  ),
                ),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '使用「域名管理」中的 Cloudflare API Token 自动创建隧道并生成运行 Token，免 cert.pem / cert 登录；要求该 API Token 含「Account › Cloudflare Tunnel › Edit」权限。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _subCtrl,
                decoration: InputDecoration(
                    labelText: _protocol.isWeb
                        ? '访问域名（如 app.example.com）'
                        : '入口子域名（客户端经 Access 接入）',
                    prefixIcon: const Icon(Icons.link_rounded),
                    helperText: _boundDomain == null
                        ? '填写后保存时将自动在 Cloudflare 绑定 DNS 路由，列表即可显示访问 URL'
                        : '已绑定 DNS 路由，可在浏览器访问',
                    suffixIcon: _boundDomain != null
                        ? const Icon(Icons.check_circle_rounded,
                            color: Colors.green)
                        : null),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _binding ? null : _bindDomain,
                    icon: _binding
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.route_rounded, size: 17),
                    label: const Text('绑定 DNS 路由'),
                  ),
                ),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '用「域名管理」API Token（需含 Zone › DNS › Edit 权限）把上方访问域名 CNAME 指向该隧道并写入云端 ingress，保存后自动生效；Token 隧道不绑域名则没有访问地址。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
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
            const Divider(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('定时启停', style: TextStyle(fontSize: 14)),
              subtitle: const Text('按时间段自动启动/停止，适合办公时段（如工作日 09:00-18:00）',
                  style: TextStyle(fontSize: 12)),
              value: _scheduleEnabled,
              onChanged: (v) => setState(() => _scheduleEnabled = v),
            ),
            if (_scheduleEnabled) ...[
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                    child: _timeField(
                        '开始时间', _scheduleStart,
                        (v) => setState(() => _scheduleStart = v))),
                const SizedBox(width: 10),
                Expanded(
                    child: _timeField(
                        '结束时间', _scheduleEnd,
                        (v) => setState(() => _scheduleEnd = v))),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    label: Text('周${'一二三四五六日'[d - 1]}'),
                    selected: _scheduleDays.contains(d),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _scheduleDays.add(d);
                      } else {
                        _scheduleDays.remove(d);
                      }
                      if (_scheduleDays.isEmpty) _scheduleEnabled = false;
                    }),
                  ),
              ]),
              const SizedBox(height: 4),
              Text('跨天时段（如 22:00-06:00）与所选星期均生效',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey)),
            ],
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
