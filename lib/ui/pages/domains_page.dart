import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/cloudflare.dart';
import '../../core/services/app_controller.dart';

/// 域名管理（替代 Cloudflare 网页端操作）：
/// 列出托管域名、DNS 记录，新增/删除 CNAME（隧道路由绑定）
class DomainsPage extends StatefulWidget {
  const DomainsPage({super.key});

  @override
  State<DomainsPage> createState() => _DomainsPageState();
}

class _DomainsPageState extends State<DomainsPage> {
  final _tokenCtrl = TextEditingController();
  bool _saving = false;
  String? _tokenError;

  List<CfZone>? _zones;
  String? _loadingZoneId;
  final Map<String, List<CfDnsRecord>> _records = {};
  String? _loadError;
  bool _refreshing = false;

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final cf = app.cf;

    if (!cf.configured) {
      return _TokenSetup(app: app, cf: cf);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _zones == null || _refreshing ? null : _refresh,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('刷新'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(children: [
              Text('域名管理',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showTokenEditor(app),
                icon: const Icon(Icons.key_rounded, size: 16),
                label: const Text('更换 Token'),
              ),
            ]),
            const SizedBox(height: 6),
            Text('直接管理 Cloudflare 托管域名与 DNS 记录，无需登录网页控制台',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            if (_loadError != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded,
                      color: Colors.red.shade300, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_loadError!)),
                ]),
              ),
            if (_zones == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_zones!.isEmpty)
              const _EmptyZones()
            else
              ..._zones!.map((z) => _ZoneCard(
                    zone: z,
                    records: _records[z.id] ?? [],
                    loading: _loadingZoneId == z.id,
                    onExpand: () => _loadRecords(z),
                    onCreateRecord: () => _showCreateRecord(z),
                    onDeleteRecord: (r) => _deleteRecord(z, r),
                  )),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _loadError = null;
    });
    try {
      final app = context.read<AppController>();
      final zones = await app.cf.listZones();
      setState(() {
        _zones = zones;
        _records.clear();
      });
    } catch (e) {
      setState(() => _loadError = e.toString());
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _loadRecords(CfZone z) async {
    if (_records.containsKey(z.id)) return;
    setState(() => _loadingZoneId = z.id);
    try {
      final app = context.read<AppController>();
      final recs = await app.cf.listDnsRecords(z.id);
      setState(() => _records[z.id] = recs);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _loadingZoneId = null);
    }
  }

  Future<void> _deleteRecord(CfZone z, CfDnsRecord r) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('删除 DNS 记录'),
              content: Text('确定删除 ${r.type} 记录 ${r.name} → ${r.content}？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除')),
              ],
            ));
    if (ok != true) return;
    if (!mounted) return;
    try {
      final app = context.read<AppController>();
      await app.cf.deleteDnsRecord(z.id, r.id);
      setState(() {
        _records[z.id]?.removeWhere((e) => e.id == r.id);
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已删除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
  }

  void _showCreateRecord(CfZone z) {
    showDialog(
        context: context,
        builder: (_) => _CreateRecordDialog(
              zone: z,
              onCreated: (r) {
                setState(() {
                  _records.putIfAbsent(z.id, () => []).add(r);
                  _records[z.id]!.sort((a, b) => a.name.compareTo(b.name));
                });
              },
            ));
  }

  void _showTokenEditor(AppController app) {
    _tokenCtrl.text = app.cf.apiToken ?? '';
    showDialog(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Cloudflare API Token'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: _tokenCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'API Token',
                      prefixIcon: Icon(Icons.key_rounded),
                      helperText: '需授予 Zone:Read + DNS:Edit 权限，推荐使用 API Token 而非全局 Key'),
                ),
                if (_tokenError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_tokenError!,
                        style: TextStyle(
                            color: Colors.red.shade300, fontSize: 12)),
                  ),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: _saving
                        ? null
                        : () async {
                            setState(() {
                              _saving = true;
                              _tokenError = null;
                            });
                            final ok =
                                await app.saveCfToken(_tokenCtrl.text);
                            if (!mounted) return;
                            setState(() => _saving = false);
                            if (ok) {
                              Navigator.pop(context);
                              _refresh();
                            } else {
                              setState(() => _tokenError =
                                  app.cf.lastError ?? 'Token 验证失败');
                            }
                          },
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('保存并验证')),
              ],
            ));
  }
}

class _TokenSetup extends StatelessWidget {
  final AppController app;
  final dynamic cf;
  const _TokenSetup({required this.app, required this.cf});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('域名管理',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.vpn_key_rounded,
                  size: 36, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              const Text('配置 Cloudflare API Token',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                  '配置后可在本工具内直接管理托管域名与 DNS 记录，无需登录 Cloudflare 网页控制台。'),
              const SizedBox(height: 12),
              _TokenForm(app: app),
            ]),
          ),
        ),
      ],
    );
  }
}

class _TokenForm extends StatefulWidget {
  final AppController app;
  const _TokenForm({required this.app});

  @override
  State<_TokenForm> createState() => _TokenFormState();
}

class _TokenFormState extends State<_TokenForm> {
  final _ctrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _ctrl,
        maxLines: 3,
        decoration: const InputDecoration(
            labelText: 'API Token',
            prefixIcon: Icon(Icons.key_rounded),
            helperText: '在 Cloudflare 控制台 → My Profile → API Tokens 创建，权限选 Zone:Read + DNS:Edit'),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Icon(Icons.error_outline_rounded,
                color: Colors.red.shade300, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text(_error!, style: TextStyle(color: Colors.red.shade300, fontSize: 12))),
          ]),
        ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _saving
            ? null
            : () async {
                setState(() {
                  _saving = true;
                  _error = null;
                });
                final ok = await widget.app.saveCfToken(_ctrl.text);
                if (!mounted) return;
                setState(() => _saving = false);
                if (!ok) {
                  setState(() => _error = widget.app.cf.lastError ?? 'Token 验证失败');
                }
              },
        icon: const Icon(Icons.verified_user_rounded, size: 18),
        label: _saving
            ? const SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('保存并验证'),
      ),
    ]);
  }
}

class _EmptyZones extends StatelessWidget {
  const _EmptyZones();

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(children: [
            Icon(Icons.public_off_rounded,
                size: 44, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            const Text('该账户下没有激活的托管域名'),
            const SizedBox(height: 4),
            Text('请先在 Cloudflare 控制台添加域名并完成 NS 迁移',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}

class _ZoneCard extends StatefulWidget {
  final CfZone zone;
  final List<CfDnsRecord> records;
  final bool loading;
  final VoidCallback onExpand;
  final VoidCallback onCreateRecord;
  final void Function(CfDnsRecord) onDeleteRecord;

  const _ZoneCard({
    required this.zone,
    required this.records,
    required this.loading,
    required this.onExpand,
    required this.onCreateRecord,
    required this.onDeleteRecord,
  });

  @override
  State<_ZoneCard> createState() => _ZoneCardState();
}

class _ZoneCardState extends State<_ZoneCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(children: [
        ListTile(
          leading: Icon(Icons.public_rounded,
              color: Theme.of(context).colorScheme.primary),
          title: Text(widget.zone.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('NS: ${widget.zone.nameServers}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.zone.status,
                style: TextStyle(
                    color: widget.zone.status == 'active'
                        ? Colors.green.shade300
                        : Colors.orange.shade300,
                    fontSize: 12)),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more),
          ]),
          onTap: () {
            setState(() => _expanded = !_expanded);
            if (_expanded) widget.onExpand();
          },
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('DNS 记录（${widget.records.length}）',
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: widget.onCreateRecord,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('添加记录'),
                ),
              ]),
              const SizedBox(height: 8),
              if (widget.loading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (widget.records.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('暂无 DNS 记录', style: TextStyle(color: Colors.grey)),
                )
              else
                ...widget.records.map((r) => _RecordTile(
                      record: r,
                      onDelete: () => widget.onDeleteRecord(r),
                    )),
            ]),
          ),
      ]),
    );
  }
}

class _RecordTile extends StatelessWidget {
  final CfDnsRecord record;
  final VoidCallback onDelete;
  const _RecordTile({required this.record, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: record.proxied
                  ? Colors.orange.withValues(alpha: 0.15)
                  : Colors.grey.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4)),
          child: Text(record.type,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(record.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(record.content,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        if (record.isTunnel)
          Tooltip(
            message: '已绑定 Cloudflare Tunnel',
            child: Icon(Icons.link_rounded,
                size: 16, color: Colors.green.shade300),
          ),
        if (record.proxied)
          Tooltip(
            message: '已开启 Cloudflare 代理',
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(Icons.cloud_done_rounded,
                  size: 16, color: Colors.orange.shade300),
            ),
          ),
        IconButton(
          tooltip: '删除记录',
          icon: const Icon(Icons.delete_outline_rounded, size: 18),
          onPressed: onDelete,
        ),
      ]),
    );
  }
}

class _CreateRecordDialog extends StatefulWidget {
  final CfZone zone;
  final void Function(CfDnsRecord) onCreated;
  const _CreateRecordDialog({required this.zone, required this.onCreated});

  @override
  State<_CreateRecordDialog> createState() => _CreateRecordDialogState();
}

class _CreateRecordDialogState extends State<_CreateRecordDialog> {
  final _nameCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  String _type = 'CNAME';
  bool _proxied = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('添加 DNS 记录 · ${widget.zone.name}'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: '记录类型'),
            items: const [
              DropdownMenuItem(value: 'CNAME', child: Text('CNAME（推荐，用于隧道绑定）')),
              DropdownMenuItem(value: 'A', child: Text('A')),
              DropdownMenuItem(value: 'AAAA', child: Text('AAAA')),
              DropdownMenuItem(value: 'TXT', child: Text('TXT')),
              DropdownMenuItem(value: 'MX', child: Text('MX')),
            ],
            onChanged: (v) => setState(() => _type = v!),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
                labelText: '名称（子域名）',
                prefixText: _type == 'CNAME' ? '' : '',
                suffixText: '.${widget.zone.name}'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _contentCtrl,
            decoration: const InputDecoration(
                labelText: '内容',
                helperText: '隧道绑定场景请填写 <隧道UUID>.cfargotunnel.com'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('开启 Cloudflare 代理（橙色云朵）',
                style: TextStyle(fontSize: 14)),
            value: _proxied,
            onChanged: (v) => setState(() => _proxied = v),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Icon(Icons.error_outline_rounded,
                    color: Colors.red.shade300, size: 16),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(_error!,
                        style: TextStyle(
                            color: Colors.red.shade300, fontSize: 12))),
              ]),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('创建')),
      ],
    );
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final content = _contentCtrl.text.trim();
    if (name.isEmpty || content.isEmpty) {
      setState(() => _error = '名称与内容不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final app = context.read<AppController>();
      final fullName = name.contains('.') ? name : '$name.${widget.zone.name}';
      final r = await app.cf.createDnsRecord(
        zoneId: widget.zone.id,
        type: _type,
        name: fullName,
        content: content,
        proxied: _proxied,
      );
      widget.onCreated(r);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
