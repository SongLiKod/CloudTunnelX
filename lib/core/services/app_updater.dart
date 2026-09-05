import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'binary_manager.dart';

/// 应用自身更新检查与升级：
/// - 通过 GitHub Releases API 获取最新版本（tag 形如 v1.1.0）
/// - Windows：下载 zip → 解压覆盖 → 自动重启（无需手动替换文件）
/// - Android：跳转浏览器下载 APK 手动安装（平台限制无法静默安装）
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

  /// 执行升级。Windows 静默替换并重启；
  /// Android 打开下载页（APK 需用户手动确认安装）。
  /// Windows 完成前会调用 [onExit] 关闭当前应用进程。
  Future<void> downloadAndInstall({VoidCallback? onExit}) async {
    final latest = _latestVersion;
    if (latest == null) throw StateError('暂无可用版本信息，请先检查更新');

    if (Platform.isAndroid) {
      await launchUrl(
        Uri.parse('https://github.com/$_repo/releases/download/v$latest/'
            'cloudtunnelx-android-v$latest.apk'),
        mode: LaunchMode.externalApplication,
      );
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

    // 1) 下载发布包（支持进度回调）
    _downloading = true;
    _progress = 0;
    notifyListeners();
    try {
      final client = http.Client();
      final res = await client.send(http.Request(
          'GET',
          Uri.parse('https://github.com/$_repo/releases/download/v$latest/'
              'cloudtunnelx-windows-v$latest.zip')));
      if (res.statusCode != 200) {
        client.close();
        throw HttpException('下载失败 HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final sink = File(zipPath).openWrite();
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
      if (File(zipPath).lengthSync() < 1024 * 1024) {
        throw HttpException('下载文件异常，请重试');
      }
    } finally {
      _downloading = false;
      notifyListeners();
    }

    // 2) 生成升级脚本并交由独立 cmd 执行，随后退出当前进程：
    //    等待主进程退出解锁 exe → PowerShell 解压覆盖 → 重启 → 自清理
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final batPath = '$exeDir${Platform.pathSeparator}updater.bat';
    File(batPath).writeAsStringSync('''
@echo off
rem CloudTunnelX 自动升级脚本
timeout /t 3 /nobreak >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '$zipPath' -DestinationPath '$exeDir' -Force"
if errorlevel 1 goto :failed
del /q "$zipPath"
start "" "$exePath"
goto :eof
:failed
del /q "$zipPath"
''');
    await Process.start('cmd', ['/c', batPath]);
    onExit?.call();
  }
}