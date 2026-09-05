import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models/log_entry.dart';
import '../../core/models/protocol_type.dart';
import '../../core/services/app_controller.dart';
import '../widgets/common.dart';

/// 日志面板（需求 3.4）：实时输出 / 按协议与隧道分类 / 智能报错解析 / 导出 / 清空
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String? _tunnelFilter;
  ProtocolType? _protocolFilter;
  bool _onlyProblems = false;
  final _scrollCtrl = ScrollController();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final entries = app.logs.entries.reversed.where((e) {
      if (_tunnelFilter != null && e.tunnelId != _tunnelFilter) return false;
      if (_protocolFilter != null && e.protocol != _protocolFilter) return false;
      if (_onlyProblems &&
          e.level != LogLevel.error &&
          e.level != LogLevel.warn) {
        return false;
      }
      return true;
    }).toList();

    final tunnelNames = <String, String>{
      for (final c in app.tunnels.all) c.id: c.name,
    };

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: Row(mainAxisSize: MainAxisSize.min, children: [
        FloatingActionButton.small(
          heroTag: 'export',
          tooltip: '导出日志',
          onPressed: () async {
            final path = await app.logs.export();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('已导出: $path'),
                  action: SnackBarAction(
                      label: '复制路径',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: path)))));
            }
          },
          child: const Icon(Icons.file_download_outlined),
        ),
        const SizedBox(width: 8),
        FloatingActionButton.small(
          heroTag: 'clear',
          tooltip: '清空日志',
          onPressed: () => app.logs.clear(),
          child: const Icon(Icons.delete_sweep_outlined),
        ),
      ]),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Text('运行日志',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  initialValue: _tunnelFilter,
                  isDense: true,
                  decoration:
                      const InputDecoration(labelText: '按隧道', isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部隧道')),
                    ...tunnelNames.entries
                        .map((e) => DropdownMenuItem(
                            value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setState(() => _tunnelFilter = v),
                ),
              ),
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<ProtocolType>(
                  initialValue: _protocolFilter,
                  isDense: true,
                  decoration:
                      const InputDecoration(labelText: '按协议', isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部协议')),
                    ...ProtocolType.values
                        .map((p) => DropdownMenuItem(value: p, child: Text(p.label))),
                  ],
                  onChanged: (v) => setState(() => _protocolFilter = v),
                ),
              ),
              FilterChip(
                label: const Text('仅看异常', style: TextStyle(fontSize: 13)),
                selected: _onlyProblems,
                onSelected: (v) => setState(() => _onlyProblems = v),
              ),
              Text('${entries.length} 条',
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text('暂无日志，启动隧道后将实时输出',
                        style: Theme.of(context).textTheme.bodySmall))
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 90),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        color: (e.level == LogLevel.error ||
                                e.level == LogLevel.warn)
                            ? logColor(e.level).withValues(alpha: 0.08)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(logIcon(e.level),
                                    size: 15, color: logColor(e.level)),
                                const SizedBox(width: 6),
                                Text('${e.timeText} · ${e.tunnelName}',
                                    style: TextStyle(
                                        fontSize: 11.5,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)),
                                if (e.protocol != null) ...[
                                  const SizedBox(width: 6),
                                  Text('· ${e.protocol!.label}',
                                      style: TextStyle(
                                          fontSize: 11.5,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary)),
                                ],
                              ]),
                              const SizedBox(height: 4),
                              SelectableText(e.message,
                                  style: const TextStyle(
                                      fontSize: 12.5, fontFamily: 'Consolas')),
                              if (e.fixHint != null) ...[
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                      color: Colors.green.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(6)),
                                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Icon(Icons.auto_fix_high_rounded,
                                        size: 14, color: Colors.green.shade300),
                                    const SizedBox(width: 6),
                                    Expanded(
                                        child: SelectableText('修复方案：${e.fixHint}',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.green.shade200))),
                                  ]),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
