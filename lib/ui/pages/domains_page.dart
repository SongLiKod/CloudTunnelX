import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/cf_account.dart';
import '../../core/models/cloudflare.dart';
import '../../core/services/app_controller.dart';
import '../../core/services/cloudflare_service.dart';

/// 域名管理（替代 Cloudflare 网页端操作）：
/// 支持多 Cloudflare 账号（每个 Token 一个显示名称），
/// 分账号列出托管域名与 DNS 记录，新增/删除 CNAME（隧道路由绑定）
class DomainsPage extends StatefulWidget {
  const DomainsPage({super.key});

  @override
  State<DomainsPage> createState() => _DomainsPageState();
}

class _DomainsPageState extends State<DomainsPage> {
  /// accountId -> 该账号下的域名列表（null 表示尚未加载完成）
  final Map<String, List<CfZone>> _zonesBy = {};
  final Map<String, bool> _loadingAcc = {};
  final Map<String, String> _accError = {};

  /// 各账号对应的 CloudflareService 实例
  final Map<String, CloudflareService> _svc = {};

  /// zoneId -> DNS 记录
  final Map<String, List<CfDnsRecord>> _records = {};
  String? _loadingZoneId;
  bool _refreshing = false;
  final Set<String> _requested = {};

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final accounts = app.cfAccounts;

    if (accounts.isEmpty) return _TokenSetup(app: app);

    // 逐账号自动加载（含从添加账号成功后切换过来）
    for (final acc in accounts) {
      if (!_zonesBy.containsKey(acc.id) &&
          !_requested.contains(acc.id) &&
          !_refreshing) {
        _requested.add(acc.id);
        _loadingAcc[acc.id] = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadAccount(app, acc);
        });
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _refreshing ? null : _refreshAll,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('刷新'),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
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
                onPressed: () => _showAddAccount(app),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('添加账号'),
              ),
            ]),
            const SizedBox(height: 6),
            Text('支持配置多个 Cloudflare 账号，分别管理各自的托管域名与 DNS 记录',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            ...accounts.map((acc) => _AccountCard(
                  account: acc,
                  zones: _zonesBy[acc.id],
                  loading: _loadingAcc[acc.id] == true,
                  loadingZoneId: _loadingZoneId,
                  records: _records,
                  error: _accError[acc.id],
                  onRetry: () {
                    setState(() => _zonesBy.remove(acc.id));
                    _requested.remove(acc.id);
                    _loadingAcc[acc.id] = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _loadAccount(app, acc);
                    });
                  },
                  onRename: () => _showRenameAccount(app, acc),
                  onRemove: () => _confirmRemoveAccount(app, acc),
                  onExpandZone: (z) => _loadRecords(acc, z),
                  onCreateRecord: (z) => _showCreateRecord(acc, z),
                  onDeleteRecord: (z, r) => _deleteRecord(acc, z, r),
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _loadAccount(AppController app, CfAccount account) async {
    try {
      final s = await app.serviceFor(account.id);
      _svc[account.id] = s;
      final zones = await s.listZones();
      if (!mounted) return;
      setState(() => _zonesBy[account.id] = zones);
    } catch (e) {
      if (mounted) setState(() => _accError[account.id] = '$e');
    } finally {
      if (mounted) setState(() => _loadingAcc[account.id] = false);
    }
  }

  Future<void> _refreshAll() async {
    setState(() {
      _refreshing = true;
      _zonesBy.clear();
      _records.clear();
      _accError.clear();
      _requested.clear();
    });
    final app = context.read<AppController>();
    final accounts = app.cfAccounts;
    await Future.wait([
      for (final acc in accounts) _loadAccount(app, acc),
    ]);
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _loadRecords(CfAccount account, CfZone z) async {
    if (_records.containsKey(z.id)) return;
    setState(() => _loadingZoneId = z.id);
    try {
      final s = _svc[account.id];
      if (s == null) return;
      final recs = await s.listDnsRecords(z.id);
      if (mounted) setState(() => _records[z.id] = recs);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _loadingZoneId = null);
    }
  }

  Future<void> _deleteRecord(CfAccount account, CfZone z, CfDnsRecord r) async {
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
      final s = _svc[account.id];
      if (s == null) return;
      await s.deleteDnsRecord(z.id, r.id);
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

  void _showCreateRecord(CfAccount account, CfZone z) {
    final s = _svc[account.id];
    if (s == null) return;
    showDialog(
        context: context,
        builder: (_) => _CreateRecordDialog(
              zone: z,
              service: s,
              onCreated: (r) {
                setState(() {
                  _records.putIfAbsent(z.id, () => []).add(r);
                  _records[z.id]!.sort((a, b) => a.name.compareTo(b.name));
                });
              },
            ));
  }

  void _showAddAccount(AppController app) {
    showDialog(
        context: context,
        builder: (_) => _AccountDialog(
              title: '添加 Cloudflare 账号',
              app: app,
              withToken: true,
            ));
  }

  void _showRenameAccount(AppController app, CfAccount account) {
    showDialog(
        context: context,
        builder: (_) => _AccountDialog(
              title: '重命名账号',
              app: app,
              withToken: false,
              initialName: account.name,
              onSubmit: (name, _) => app.renameCfAccount(account.id, name),
            ));
  }

  Future<void> _confirmRemoveAccount(AppController app, CfAccount account) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('删除账号'),
              content: Text('确定删除账号「${account.name}」？其 API Token 与缓存将一并清除。'),
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
    await app.removeCfAccount(account.id);
    setState(() {
      _zonesBy.remove(account.id);
      _svc.remove(account.id);
      _accError.remove(account.id);
      _requested.remove(account.id);
    });
  }
}

/// 单账号卡片：头部显示名称与 Token 掩码，下方为该账号下的域名列表
class _AccountCard extends StatelessWidget {
  final CfAccount account;
  final List<CfZone>? zones;
  final bool loading;
  final String? loadingZoneId;
  final Map<String, List<CfDnsRecord>> records;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onRename;
  final VoidCallback onRemove;
  final void Function(CfZone) onExpandZone;
  final void Function(CfZone) onCreateRecord;
  final void Function(CfZone, CfDnsRecord) onDeleteRecord;

  const _AccountCard({
    required this.account,
    required this.zones,
    required this.loading,
    required this.loadingZoneId,
    required this.records,
    required this.error,
    required this.onRetry,
    required this.onRename,
    required this.onRemove,
    required this.onExpandZone,
    required this.onCreateRecord,
    required this.onDeleteRecord,
  });

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final name = account.name;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(children: [
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            child: Text(name.isEmpty ? '?' : name.characters.first,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: FutureBuilder<String>(
            future: app.tokenMaskFor(account.id),
            builder: (_, snap) => Text(
              snap.data == null || snap.data!.isEmpty
                  ? 'Token 未配置'
                  : 'Token · ${snap.data}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '账号操作',
            onSelected: (v) {
              if (v == 'rename') onRename();
              if (v == 'remove') onRemove();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'remove', child: Text('删除账号')),
            ],
          ),
        ),
        const Divider(height: 1),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (error != null)
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(Icons.error_outline_rounded,
                  color: Colors.red.shade300, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(error!)),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ]),
          )
        else if (zones == null)
          const SizedBox.shrink()
        else if (zones!.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: Text('该账号下没有激活的托管域名',
                    style: TextStyle(color: Colors.grey))),
          )
        else
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text('托管域名（${zones!.length}）',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
              const SizedBox(height: 4),
              ...zones!.map((z) => _ZoneCard(
                    zone: z,
                    records: records[z.id] ?? const [],
                    loading: loadingZoneId == z.id,
                    onExpand: () => onExpandZone(z),
                    onCreateRecord: () => onCreateRecord(z),
                    onDeleteRecord: (r) => onDeleteRecord(z, r),
                  )),
            ]),
          ),
      ]),
    );
  }
}

/// 首次引导或添加账号对话框
class _AccountDialog extends StatefulWidget {
  final String title;
  final AppController app;
  final bool withToken;
  final bool inline;
  final String initialName;
  final Future<void> Function(String name, String token)? onSubmit;

  const _AccountDialog({
    required this.title,
    required this.app,
    required this.withToken,
    this.inline = false,
    this.initialName = '',
    this.onSubmit,
  });

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  late final TextEditingController _nameCtrl;
  final _tokenCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Column _buildForm() {
    final nameField = TextField(
      controller: _nameCtrl,
      decoration: const InputDecoration(
          labelText: '账号名称',
          prefixIcon: Icon(Icons.label_outline_rounded),
          helperText: '用于区分多个账号，如：个人站 / 公司站'),
    );
    final tokenField = widget.withToken
        ? Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TextField(
              controller: _tokenCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'API Token',
                  prefixIcon: Icon(Icons.key_rounded),
                  helperText:
                      '在 Cloudflare 控制台 → My Profile → API Tokens 创建，权限选 Zone:Read + DNS:Edit'),
            ),
          )
        : const SizedBox.shrink();
    final errorBox = _error != null
        ? Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Icon(Icons.error_outline_rounded,
                  color: Colors.red.shade300, size: 16),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(_error!,
                      style: TextStyle(
                          color: Colors.red.shade300, fontSize: 12))),
            ]),
          )
        : const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      nameField,
      tokenField,
      errorBox,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.inline) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._buildForm().children,
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _saving ? null : _submit,
              icon: const Icon(Icons.verified_user_rounded, size: 18),
              label: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存并验证'),
            ),
          ]);
    }
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: _buildForm(),
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('保存')),
      ],
    );
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final hasCustomSubmit = widget.onSubmit != null;
    if (widget.withToken && !hasCustomSubmit && _tokenCtrl.text.trim().isEmpty) {
      setState(() => _error = '请输入 API Token');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    if (hasCustomSubmit) {
      await widget.onSubmit!(name, _tokenCtrl.text.trim());
      if (mounted && !widget.inline) Navigator.pop(context);
      setState(() => _saving = false);
      return;
    }
    final ok = await widget.app.addCfAccount(name: name, token: _tokenCtrl.text);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      if (!widget.inline) Navigator.pop(context);
    } else {
      setState(() => _error = widget.app.cf.lastError ?? 'Token 验证失败');
    }
  }
}

/// 未配置任何账号时的引导页
class _TokenSetup extends StatelessWidget {
  final AppController app;
  const _TokenSetup({required this.app});

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
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.vpn_key_rounded,
                      size: 36,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  const Text('添加 Cloudflare 账号',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text(
                      '配置后可在本工具内分账号管理托管域名与 DNS 记录，无需登录 Cloudflare 网页控制台。'),
                  const SizedBox(height: 12),
                  _AccountDialog(
                    title: '添加 Cloudflare 账号',
                    app: app,
                    withToken: true,
                    inline: true,
                  ),
                ]),
          ),
        ),
      ],
    );
  }
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
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(children: [
        ListTile(
          dense: true,
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  const SizedBox(height: 4),
                  if (widget.loading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (widget.records.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('暂无 DNS 记录',
                          style: TextStyle(color: Colors.grey)),
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
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
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
  final CloudflareService service;
  final void Function(CfDnsRecord) onCreated;
  const _CreateRecordDialog(
      {required this.zone, required this.service, required this.onCreated});

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
      final fullName = name.contains('.') ? name : '$name.${widget.zone.name}';
      final r = await widget.service.createDnsRecord(
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