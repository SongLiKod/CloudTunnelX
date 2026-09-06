import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'binary_manager.dart';

/// 应用自身更新检查与升级：
/// - 通过 GitHub Releases API 获取最新版本（tag 形如 v1.1.0）
/// - Windows：下载 zip → 解压覆盖 → 自动重启（无需手动替换文件）
/// - Android：应用内下载 APK（含进度）→ 直接调起系统安装器，不跳转浏览器
class AppUpdater extends ChangeNotifier {
  static const _repo = 'SongLiKod/CloudTunnelX';
  static const _apiLatest =
      'https://api.github.com/repos/$_repo/releases/latest';

  String? _currentVersion;
  String? _latestVersion;
  String? _releaseNotes;
  String? _error;
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;

  String? get currentVersion => _currentVersion;
  String? get latestVersion => _latestVersion;
  String? get releaseNotes => _releaseNotes;
  String? get error => _error;
  bool get checking => _checking;
  bool get downloading => _downloading;
  double get progress => _progress;

  /// 是否存在可安装的新版本（当前版本已知且晚于远端版本）
  bool get hasUpdate {
    final cur = _currentVersion;
    final latest = _latestVersion;
    if (cur == null || latest == null) return false;
    return BinaryManager.isNewerVersion(latest, cur);
  }

  /// 读取当前应用版本（package_info_plus）
  Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
      notifyListeners();
    } catch (_) {
      // 读取失败时版本未知，仅影响更新判断
    }
  }

  /// 拉取 GitHub 最新 Release，解析版本号与更新说明
  Future<void> checkForUpdate() async {
    if (_checking) return;
    _checking = true;
    _error = null;
    _latestVersion = null;
    _releaseNotes = null;
    notifyListeners();
    try {
      final res = await http
          .get(Uri.parse(_apiLatest),
              headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = ((j['tag_name'] as String?) ?? '').replaceFirst(RegExp(r'^v'), '');
      // 注意取 group(0) 完整匹配；带量词的重复捕获组只保留最后一段（如 ".0"）
      final m = RegExp(r'\d{1,3}(?:\.\d{1,3}){1,2}').firstMatch(tag);
      if (m == null) throw const FormatException('无法解析发布版本号');
      _latestVersion = m.group(0);
      final body = ((j['body'] as String?) ?? '').trim();
      _releaseNotes = body.isEmpty ? null : body;
    } catch (e) {
      _error = e.toString();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// 执行升级：
  /// - Windows：下载 zip → 静默替换并重启（完成前调用 [onExit] 关闭当前进程）
  /// - Android：应用内下载 APK → 调起系统安装器直接安装（首次需授权"安装未知应用"）
  Future<void> downloadAndInstall({VoidCallback? onExit}) async {
    final latest = _latestVersion;
    if (latest == null) throw StateError('暂无可用版本信息，请先检查更新');

    if (Platform.isAndroid) {
      // 下载到应用缓存目录（原生端 FileProvider 映射该目录）
      final cacheDir = await getTemporaryDirectory();
      final apkPath =
          '${cacheDir.path}${Platform.pathSeparator}cloudtunnelx-v$latest.apk';
      await _downloadToFile(
        'https://github.com/$_repo/releases/download/v$latest/'
        'cloudtunnelx-android-v$latest.apk',
        apkPath,
      );
      // 调起系统安装器前先做签名预检：CI 未配置稳定签名密钥时，各次构建签名不同，
      // 覆盖安装必失败，系统提示晦涩且无法安装。不一致时在此直接给出明确指引。
      const channel = MethodChannel('com.cloudtunnelx/native');
      final matches = await channel.invokeMethod<bool>(
              'signatureMatches', {'apkPath': apkPath}) ??
          false;
      if (!matches) {
        throw StateError(
            '升级包与当前已安装应用签名不一致，无法覆盖安装。\n'
            '为支持应用内升级，请在仓库 Secrets 中配置 ANDROID_KEYSTORE_BASE64 / '
            'ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_PASSWORD / ANDROID_KEY_ALIAS '
            '（固定签名密钥），并确保当前安装版本也由同一密钥签名。\n'
            '如需立即升级：请先卸载旧版再从 Release 安装（卸载会清除本地隧道配置数据）。');
      }
      await channel.invokeMethod('installApk', {'filePath': apkPath});
      return;
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('当前平台暂不支持自动升级，请到 GitHub Release 页手动更新');
    }

    final base = await getApplicationSupportDirectory();
    final updDir = Directory('${base.path}${Platform.pathSeparator}updates');
    if (!updDir.existsSync()) updDir.createSync(recursive: true);
    final zipPath =
        '${updDir.path}${Platform.pathSeparator}cloudtunnelx-windows-v$latest.zip';
    await _downloadToFile(
      'https://github.com/$_repo/releases/download/v$latest/'
      'cloudtunnelx-windows-v$latest.zip',
      zipPath,
    );

    // 生成升级脚本并交由独立 cmd 执行，随后退出当前进程：
    //    等待主进程退出解锁 exe → PowerShell 解压覆盖 → 重启
    // 解压失败时同样重启现有版本，避免升级失败后应用凭空消失。zip 保留供排查。
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final batPath = '$exeDir${Platform.pathSeparator}updater.bat';
    File(batPath).writeAsStringSync('''
@echo off
rem CloudTunnelX 自动升级脚本
timeout /t 3 /nobreak >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath '$zipPath' -DestinationPath '$exeDir' -Force; exit 0 } catch { exit 1 }"
if errorlevel 1 goto :relaunch
del /q "$zipPath"
:relaunch
start "" "$exePath"
''');
    await Process.start('cmd', ['/c', batPath]);
    onExit?.call();
  }

  /// 下载发布包到本地文件，期间通过 [_progress] 上报进度
  Future<void> _downloadToFile(String url, String destPath) async {
    _downloading = true;
    _progress = 0;
    notifyListeners();
    try {
      final client = http.Client();
      final res = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        client.close();
        throw HttpException('下载失败 HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final sink = File(destPath).openWrite();
      var received = 0;
      await for (final chunk in res.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) {
          _progress = received / total;
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      client.close();
      if (File(destPath).lengthSync() < 1024 * 1024) {
        throw HttpException('下载文件异常，请重试');
      }
    } finally {
      _downloading = false;
      notifyListeners();
    }
  }
}