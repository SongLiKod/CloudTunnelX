import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/app_controller.dart';
import '../../core/services/autostart_service.dart';

/// 设置页（需求 2.2 / 3.6 / 技术文档 4.2）：内核管理、Cloudflare 授权、开机自启、托盘说明
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _autostart = AutostartService();
  bool? _autostartOn;
  bool? _certOk;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final app = context.read<AppController>();
    _autostartOn = _autostart.supported ? await _autostart.isEnabled() : false;
    _certOk = await app.binaries.hasLoginCert();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final bm = app.binaries;
    final isAndroid = Platform.isAndroid;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('设置',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),

        // ---------- 内核管理 ----------
        _Section(
          title: 'cloudflared 内核',
          icon: Icons.memory_rounded,
          children: [
            Row(children: [
              Icon(
                bm.ready ? Icons.check_circle_rounded : Icons.cancel_rounded,
                size: 18,
                color: bm.ready ? Colors.green.shade300 : Colors.red.shade300,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bm.ready
                      ? '内核就绪 · ${bm.version ?? '版本检测中'}'
                          '${isAndroid ? '（随应用内置）' : ''}\n${bm.binaryPath}'
                      : isAndroid
                          ? '未检测到内置内核：\n'
                              '目录 ${bm.androidNativeLibDir ?? '(获取失败，需确认原生端已注册)'
                                  } 下${bm.androidKernelPresent ? '文件异常' : '未找到 libcloudflared.so'}，\n'
                              '请按下方指引内置到 APK 后重新构建安装'
                          : '未检测到 cloudflared 内核，请一键下载',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ]),
            if (bm.downloading) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: bm.progress, minHeight: 5),
              const SizedBox(height: 4),
              Text('下载中 ${(bm.progress * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 10, children: [
              if (!isAndroid)
                FilledButton.icon(
                  onPressed: bm.downloading
                      ? null
                      : () async {
                          try {
                            await bm.installLatest();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content:
                                      Text('内核安装完成：${bm.version ?? ''}')));
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text('安装失败：$e'),
                                  backgroundColor:
                                      Theme.of(context).colorScheme.error));
                            }
                          }
                        },
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('一键下载 / 更新内核'),
                ),
              FilledButton.tonal(
                onPressed: () async {
                  await bm.resolveBinary();
                },
                child: const Text('重新检测'),
              ),
              FilledButton.tonal(
                onPressed: bm.ready
                    ? () async {
                        final latest = await bm.checkUpdate();
                        if (!context.mounted) return;
                        final messenger = ScaffoldMessenger.of(context);
                        if (latest == null) {
                          messenger.showSnackBar(const SnackBar(
                              content: Text('当前已是最新版本，无需更新')));
                        } else {
                          messenger.showSnackBar(SnackBar(
                              content: Text(isAndroid
                                  ? '发现新版本 ${bm.version} → $latest，更新内核需重新构建安装（见下方指引）'
                                  : '发现新版本 ${bm.version} → $latest，可点击「一键下载 / 更新内核」升级'),
                              duration: const Duration(seconds: 4)));
                        }
                      }
                    : null,
                child: const Text('检查更新'),
              ),
            ]),
            if (isAndroid) ...[
              const SizedBox(height: 8),
              // Android 10+ W^X 策略：内核只能内置，展示如何获取/更换内置内核
              ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                childrenPadding:
                    const EdgeInsets.only(left: 8, right: 8, bottom: 4),
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text('如何获取 / 更新 Android arm64 内核？',
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.orange.shade300,
                        fontWeight: FontWeight.w600)),
                children: [
                  const _GuideRow(
                    step: '1',
                    text: 'Android 10+ 出于安全（W^X 策略）禁止执行应用可写目录里的文件，导入模式不可用；内核必须以 libcloudflared.so 随 APK 内置，运行时从安装目录（nativeLibraryDir，只读可执行）启动。',
                  ),
                  _GuideRow(
                    step: '2',
                    text: '获取内核：官方 GitHub Releases 的 cloudflared-linux-arm64（点下方按钮浏览器下载）。也可以从 Termux 获取 Android 构建版，临时穿透更稳（可规避 "lookup … on [::1]:53" 类 DNS 报错）。',
                    action: FilledButton.tonalIcon(
                      onPressed: () => launchUrl(Uri.parse(
                          'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64'),
                          mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('下载 linux-arm64'),
                    ),
                  ),
                  const _GuideRow(
                    step: '3',
                    text: '更换内置内核：把下载的二进制改名为 libcloudflared.so，放入工程目录 android/app/src/main/jniLibs/arm64-v8a/ 下，然后重新构建安装 App（flutter run / 打包 APK）。',
                  ),
                  const _GuideRow(
                    step: '4',
                    text: '内置后到这里点「重新检测」即可识别版本；若识别失败，请确认放入的是 arm64-v8a (aarch64) 架构的文件。',
                  ),
                ],
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),

        // ---------- Cloudflare 授权 ----------
        _Section(
          title: 'Cloudflare 登录授权（固定隧道必需）',
          icon: Icons.verified_user_rounded,
          children: [
            Row(children: [
              Icon(
                _certOk == true
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                size: 18,
                color:
                    _certOk == true ? Colors.green.shade300 : Colors.orange.shade300,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _certOk == true
                      ? '已完成授权（cert.pem 就绪），可创建固定隧道'
                      : '未授权：创建固定隧道前需要完成一次浏览器授权（自动打开授权页）',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 10, children: [
              FilledButton.icon(
                onPressed: bm.ready
                    ? () async {
                        await app.tunnels.startLogin();
                        // 等待用户浏览器完成授权后落盘
                        for (var i = 0; i < 60; i++) {
                          await Future.delayed(const Duration(seconds: 2));
                          if (await app.binaries.hasLoginCert()) break;
                        }
                        _refresh();
                      }
                    : null,
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('登录授权（浏览器）'),
              ),
              FilledButton.tonal(
                onPressed: _refresh,
                child: const Text('刷新状态'),
              ),
            ]),
          ],
        ),
        const SizedBox(height: 14),

        // ---------- Cloudflare API Token（域名管理） ----------
        _Section(
          title: 'Cloudflare API Token（域名管理）',
          icon: Icons.cloud_circle_rounded,
          children: [
            Row(children: [
              Icon(
                app.cf.configured
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                size: 18,
                color: app.cf.configured
                    ? Colors.green.shade300
                    : Colors.orange.shade300,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  app.cf.configured
                      ? '已配置 API Token，可在「域名管理」页直接管理 DNS 记录'
                      : '未配置：配置后可在工具内直接管理 Cloudflare 托管域名与 DNS 记录，无需登录网页控制台',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _CfTokenEditor(app: app),
          ],
        ),
        const SizedBox(height: 14),

        // ---------- 开机自启 / 托盘 ----------
        _Section(
          title: '启动与后台运行',
          icon: Icons.settings_power_rounded,
          children: [
            if (_autostart.supported)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开机自动启动（注册表 HKCU Run）'),
                subtitle: const Text('启动后自动恢复上次隧道配置，最小化至托盘运行'),
                value: _autostartOn ?? false,
                onChanged: (v) async {
                  await _autostart.setEnabled(v);
                  setState(() => _autostartOn = v);
                },
              )
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开机自启'),
                subtitle: const Text('当前平台不支持（仅 Windows 提供注册表自启）'),
                trailing: const Icon(Icons.do_not_disturb_outlined),
              ),
            if (Platform.isWindows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('关闭窗口 = 最小化到托盘'),
                subtitle: const Text('通过托盘菜单可启停隧道、复制公网地址、退出程序'),
                trailing: const Icon(Icons.check_rounded, color: Colors.green),
              ),
          ],
        ),
        const SizedBox(height: 14),

        // ---------- 外观主题 ----------
        _Section(
          title: '外观主题',
          icon: Icons.palette_outlined,
          children: [
            RadioGroup<ThemeMode>(
              groupValue: app.themeMode,
              onChanged: (v) {
                if (v != null) app.setThemeMode(v);
              },
              child: Column(children: [
                const RadioListTile<ThemeMode>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('跟随系统'),
                  subtitle: Text('自动匹配操作系统当前的浅色/深色'),
                  value: ThemeMode.system,
                ),
                const RadioListTile<ThemeMode>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('浅色'),
                  value: ThemeMode.light,
                ),
                const RadioListTile<ThemeMode>(
                  contentPadding: EdgeInsets.zero,
                  title: Text('深色'),
                  value: ThemeMode.dark,
                ),
              ]),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // ---------- 配置备份（导入/导出 JSON） ----------
        _Section(
          title: '隧道配置备份',
          icon: Icons.backup_rounded,
          children: [
            Text('将全部隧道配置导出为 JSON 文件（含名称/协议/本地端口/子域名/Token 模式，不含 API Token），可迁移到其他设备。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5)),
            const SizedBox(height: 12),
            Wrap(spacing: 10, children: [
              FilledButton.tonalIcon(
                onPressed: () async {
                  final json = app.exportConfigsJson();
                  final path = await FilePicker.saveFile(
                    dialogTitle: '导出隧道配置',
                    fileName: 'cloudtunnelx_backup_${DateTime.now().millisecondsSinceEpoch}.json',
                    type: FileType.any,
                    bytes: utf8.encode(json),
                  );
                  if (path != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已导出 ${app.tunnels.all.length} 条隧道配置到\n$path')));
                  }
                },
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('导出配置'),
              ),
              FilledButton.tonalIcon(
                onPressed: () async {
                  final picked = await FilePicker.pickFiles(
                    dialogTitle: '导入隧道配置',
                    type: FileType.custom,
                    allowedExtensions: ['json'],
                  );
                  final path = picked.isEmpty ? null : picked.first.path;
                  if (path == null) return;
                  try {
                    final json = await File(path).readAsString();
                    final n = await app.importConfigsJson(json);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('成功导入 $n 条隧道配置')));
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('导入失败：$e'),
                          backgroundColor: Theme.of(context).colorScheme.error));
                    }
                  }
                },
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('导入配置'),
              ),
            ]),
          ],
        ),
        const SizedBox(height: 14),

        // ---------- 关于 ----------
        _Section(
          title: '关于',
          icon: Icons.info_outline_rounded,
          children: [
            Row(children: [
              const Expanded(
                child: Text('云隧通 CloudTunnelX',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: app.updater.checking
                    ? null
                    : () async {
                        await app.checkAppUpdate();
                        if (context.mounted && app.updater.error != null) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('检查更新失败：${app.updater.error}'),
                              backgroundColor:
                                  Theme.of(context).colorScheme.error));
                        }
                      },
                icon: app.updater.checking
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.system_update_alt_rounded, size: 18),
                label: const Text('检查更新'),
              ),
            ]),
            const SizedBox(height: 2),
            Text('当前版本：${app.updater.currentVersion ?? '--'}',
                style: Theme.of(context).textTheme.bodySmall),
            if (app.updater.hasUpdate) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.new_releases_rounded,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                              '发现新版本 v${app.updater.latestVersion}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 14)),
                        ),
                      ]),
                      if (app.updater.releaseNotes != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          app.updater.releaseNotes!,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(height: 1.4),
                        ),
                      ],
                      const SizedBox(height: 10),
                      if (app.updater.downloading) ...[
                        LinearProgressIndicator(
                            value: app.updater.progress, minHeight: 5),
                        const SizedBox(height: 4),
                        Text(
                            '下载中 ${(app.updater.progress * 100).toStringAsFixed(0)}%',
                            style: Theme.of(context).textTheme.bodySmall),
                      ] else
                        FilledButton.icon(
                          onPressed: () async {
                            try {
                              await app.upgradeApp();
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text('升级失败：$e'),
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .error));
                              }
                            }
                          },
                          icon: Icon(isAndroid
                              ? Icons.open_in_browser_rounded
                              : Icons.system_update_alt_rounded,
                              size: 18),
                          label: Text(isAndroid
                              ? '前往下载 APK'
                              : '立即升级并重启'),
                        ),
                    ]),
              ),
            ] else if (app.updater.latestVersion != null &&
                app.updater.error == null) ...[
              const SizedBox(height: 6),
              Text('已是最新版本（v${app.updater.latestVersion}）',
                  style: TextStyle(
                      color: Colors.green.shade300, fontSize: 12.5)),
            ],
            const SizedBox(height: 8),
            Text('零服务器全协议内网穿透工具 · 双端可视化一键隧通内外网',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              '支持协议：HTTP / HTTPS / WebSocket / TCP\n'
              '不支持：UDP、QUIC、ICMP、广播/组播（cloudflared 官方内核限制）\n'
              '安全说明：全部流量为本地主动出站连接，不暴露本地端口；TCP 依托 Cloudflare Access 鉴权；配置与日志仅保存在本机。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.6),
            ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _Section(
      {required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text(title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      ),
    );
  }
}

class _CfTokenEditor extends StatefulWidget {
  final AppController app;
  const _CfTokenEditor({required this.app});

  @override
  State<_CfTokenEditor> createState() => _CfTokenEditorState();
}

class _CfTokenEditorState extends State<_CfTokenEditor> {
  final _ctrl = TextEditingController();
  bool _saving = false;
  bool _reveal = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl.text = widget.app.cf.apiToken ?? '';
  }

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
        maxLines: 2,
        obscureText: !_reveal,
        decoration: InputDecoration(
          labelText: 'API Token',
          prefixIcon: const Icon(Icons.key_rounded),
          helperText: '创建步骤：Cloudflare 控制台 → 右上角头像 → My Profile → API Tokens → Create Token → 「Edit zone DNS」模板 → 选择域名 Zone → 勾选 Zone:Read + DNS:Edit 权限 → 创建后粘贴到此处。Token 加密存储在本机（Windows DPAPI / Android Keystore）。',
          suffixIcon: IconButton(
            icon: Icon(_reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                size: 18),
            onPressed: () => setState(() => _reveal = !_reveal),
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Icon(Icons.error_outline_rounded,
                color: Colors.red.shade300, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text(_error!,
                style: TextStyle(color: Colors.red.shade300, fontSize: 12))),
          ]),
        ),
      const SizedBox(height: 10),
      Wrap(spacing: 10, children: [
        FilledButton.icon(
          onPressed: _saving
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  setState(() {
                    _saving = true;
                    _error = null;
                  });
                  final ok = await widget.app.saveCfToken(_ctrl.text);
                  if (!mounted) return;
                  setState(() => _saving = false);
                  if (ok) {
                    messenger.showSnackBar(
                        const SnackBar(content: Text('Token 验证成功，已保存')));
                  } else {
                    setState(() =>
                        _error = widget.app.cf.lastError ?? 'Token 验证失败');
                  }
                },
          icon: const Icon(Icons.verified_user_rounded, size: 18),
          label: _saving
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('保存并验证'),
        ),
        if (widget.app.cf.configured)
          TextButton.icon(
            onPressed: _saving ? null : () async {
              await widget.app.clearCfToken();
              _ctrl.clear();
              setState(() => _error = null);
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('清除 Token'),
          ),
      ]),
    ]);
  }
}

/// 内核获取教程中的一行：序号圆点 + 说明（可带操作按钮）
class _GuideRow extends StatelessWidget {
  final String step;
  final String text;
  final Widget? action;
  const _GuideRow({required this.step, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration:
              BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
          child: Text(step,
              style: TextStyle(
                  fontSize: 10,
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: Theme.of(context).textTheme.bodySmall),
                if (action != null) ...[const SizedBox(height: 6), action!],
              ]),
        ),
      ]),
    );
  }
}
