import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// cloudflared 内核管理（技术文档 2.3.4 / 4.1 / 5.1）：
/// 查找内置内核 → 系统安装 → 一键下载，全程静默调用、无命令行窗口。
class BinaryManager extends ChangeNotifier {
  static const _winAsset = 'cloudflared-windows-amd64.exe';
  static const _linuxAsset = 'cloudflared-linux-amd64';
  static const _releaseUrl =
      'https://github.com/cloudflare/cloudflared/releases/latest/download';

  /// Android 10+（W^X 策略）禁止执行应用可写目录中的文件，
  /// 内核必须以 libcloudflared.so 内置在 jniLibs，从 nativeLibraryDir 执行
  /// （详见 settings_page 的「如何获取 Android arm64 内核？」指引）。
  static const _androidLib = 'libcloudflared.so';
  static const _nativeChannel = MethodChannel('com.cloudtunnelx/native');

  String? _binaryPath;
  String? _version;
  bool _downloading = false;
  double _progress = 0;

  // Android 诊断信息：内置内核目录及是否存在（供设置页展示失败原因）
  String? _androidLibDir;
  bool _androidKernelPresent = false;

  String? get binaryPath => _binaryPath;
  String? get version => _version;
  bool get downloading => _downloading;
  double get progress => _progress;
  bool get ready => _binaryPath != null;
  String? get androidNativeLibDir => _androidLibDir;
  bool get androidKernelPresent => _androidKernelPresent;

  String? _customBinDir;

  /// 用户自定义内核目录（null 表示使用默认：软件目录下的 bin 插件目录）
  String? get customBinDir => _customBinDir;

  /// 设置自定义内核目录（null 恢复默认）。变更后请重新检测内核。
  void setCustomBinDir(String? path) {
    final v = (path == null || path.trim().isEmpty) ? null : path.trim();
    if (_customBinDir == v) return;
    _customBinDir = v;
    notifyListeners();
  }

  /// 内核安装目录：自定义目录 > 软件目录下 bin（插件目录）> AppSupport/bin 兜底。
  /// 桌面端默认放在本软件目录下的 bin（需求：插件目录应位于软件自身目录），
  /// 若软件目录不可写（Program Files、受管控目录）则自动回退 AppSupport。
  /// Android 无需下载内核，固定 AppSupport/bin（释放 cacert.pem 用）。
  Future<Directory> binDir() async {
    final custom = _customBinDir;
    if (custom != null && custom.isNotEmpty) {
      final dir = Directory(custom);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
    if (!Platform.isAndroid &&
        Platform.resolvedExecutable.contains(Platform.pathSeparator)) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final dir = Directory('$exeDir${Platform.pathSeparator}bin');
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return dir;
      } catch (_) {
        // 软件目录不可写时回退 AppSupport
      }
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}bin');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Cloudflare 凭证目录：~/.cloudflared
  Future<Directory> cloudflaredHome() async {
    if (Platform.isWindows) {
      final userprofile = Platform.environment['USERPROFILE'] ?? '.';
      return Directory('$userprofile\\.cloudflared');
    }
    final home = Platform.environment['HOME'] ?? '/';
    return Directory('$home/.cloudflared');
  }

  /// Android 无系统证书路径（/etc/ssl/certs 不存在），Go 程序 TLS 校验会报
  /// "certificate signed by unknown authority"。从应用内置资源释放 Mozilla
  /// CA 根证书包，启动内核时通过 SSL_CERT_FILE 环境变量注入。
  Future<String> ensureCaBundle() async {
    final support = await binDir();
    final file = File(
        '${support.parent.path}${Platform.pathSeparator}cacert.pem');
    if (!file.existsSync()) {
      final bytes = await rootBundle.load('assets/cacert.pem');
      await file.writeAsBytes(bytes.buffer.asUint8List());
    }
    return file.path;
  }

  Future<String?> resolveBinary() async {
    final exeName = Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';

    // 0) Android：内置内核（nativeLibraryDir，可执行且只读）
    if (Platform.isAndroid) {
      _androidLibDir = await _androidNativeLibDir();
      final libDir = _androidLibDir;
      if (libDir != null) {
        final lib = '$libDir${Platform.pathSeparator}$_androidLib';
        final f = File(lib);
        _androidKernelPresent = f.existsSync() && f.lengthSync() > 1024;
        if (_androidKernelPresent) {
          _binaryPath = lib;
          await detectVersion();
          return lib;
        }
      }
      _binaryPath = null;
      notifyListeners();
      return null;
    }

    // 1) 自定义目录 → 软件根目录 /bin/（技术文档 4.3）与 AppSupport/bin
    final candidates = <String>[];
    final sep = Platform.pathSeparator;
    final custom = _customBinDir;
    if (custom != null && custom.isNotEmpty) {
      candidates.add('$custom$sep$exeName');
    }
    if (Platform.resolvedExecutable.contains(sep)) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir${sep}bin$sep$exeName');
      candidates.add('$exeDir$sep$exeName');
    }
    final support = await binDir();
    candidates.add('${support.path}$sep$exeName');
    // 兼容历史安装：旧版本内核默认安装在 AppSupport/bin（现默认已迁移到软件目录/bin）
    if (!Platform.isAndroid) {
      final base = await getApplicationSupportDirectory();
      candidates.add('${base.path}${sep}bin$sep$exeName');
    }

    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync() && f.lengthSync() > 1024) {
        _binaryPath = c;
        await detectVersion();
        return c;
      }
    }

    // 2) 系统 PATH
    try {
      final which = Platform.isWindows ? 'where' : 'which';
      final res = await Process.run(which, [exeName],
          runInShell: Platform.isWindows);
      if (res.exitCode == 0) {
        final first = res.stdout.toString().trim().split('\n').first.trim();
        if (first.isNotEmpty && File(first).existsSync()) {
          _binaryPath = first;
          await detectVersion();
          return first;
        }
      }
    } catch (_) {}

    _binaryPath = null;
    _version = null;
    notifyListeners();
    return null;
  }

  /// Android：nativeLibraryDir（内置 so 的安装目录）；非 Android 或失败返回 null
  Future<String?> _androidNativeLibDir() async {
    try {
      final v = await _nativeChannel.invokeMethod<String>('nativeLibraryDir');
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> detectVersion() async {
    if (_binaryPath == null) return;
    try {
      final res = await Process.run(_binaryPath!, ['--version'],
          runInShell: Platform.isWindows);
      final out = res.stdout.toString().trim();
      final m = RegExp(r'(\d{4}\.\d+\.\d+|\d+\.\d+\.\d+)').firstMatch(out);
      _version = m?.group(1) ?? (out.isEmpty ? '未知版本' : out);
    } catch (_) {
      _version = null;
    }
    notifyListeners();
  }

  /// 一键下载内核（需求 2.2：内置/可一键安装，无需用户手动配置环境）
  Future<String> installLatest() async {
    if (Platform.isAndroid) {
      throw UnsupportedError(
          'Android 内核随应用内置（libcloudflared.so），无需下载；如需更换内核请重新构建安装。');
    }
    final asset = Platform.isWindows ? _winAsset : _linuxAsset;
    final dir = await binDir();
    // 提前校验目标目录可写：权限被拒时给出明确指引，而非下载完才报错
    try {
      final probe = File('${dir.path}${Platform.pathSeparator}.writable_probe');
      await probe.writeAsString('');
      await probe.delete();
    } catch (e) {
      final reason = e is FileSystemException && e.osError != null
          ? e.osError!.message
          : '$e';
      throw FileSystemException(
        '内核安装目录不可写：${dir.path}\n'
        '原因：$reason\n'
        '请在设置页选择你有权限的目录作为「自定义内核目录」。',
        dir.path,
      );
    }
    final target =
        '${dir.path}${Platform.pathSeparator}${Platform.isWindows ? "cloudflared.exe" : "cloudflared"}';

    _downloading = true;
    _progress = 0;
    notifyListeners();
    try {
      final client = http.Client();
      final req = http.Request('GET', Uri.parse('$_releaseUrl/$asset'));
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw HttpException('下载失败 HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final sink = File('$target.download').openWrite();
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
      final dl = File('$target.download');
      if (dl.lengthSync() < 1024) throw HttpException('下载文件异常，请重试');
      // Linux 需要可执行权限；Windows 直接改名
      if (Platform.isWindows) {
        if (File(target).existsSync()) File(target).deleteSync();
        dl.renameSync(target);
      } else {
        // 先改名落地，再授予可执行权限（此前顺序颠倒，chmod 时 target 尚不存在）
        if (File(target).existsSync()) File(target).deleteSync();
        dl.renameSync(target);
        await Process.run('chmod', ['755', target]);
      }
      _binaryPath = target;
      await detectVersion();
      return target;
    } finally {
      _downloading = false;
      notifyListeners();
    }
  }

  /// 非 Android 平台从用户选择的文件导入内核（Android 10+ 禁止执行可写目录文件，故不支持）
  Future<String> importBinary(String sourcePath) async {
    if (Platform.isAndroid) {
      throw UnsupportedError(
          'Android 10+ 禁止执行应用可写目录中的文件，内核需以 libcloudflared.so 内置到 APK，'
          '请将内核文件替换到 android/app/src/main/jniLibs/arm64-v8a/ 后重新构建安装。');
    }
    if (Platform.isWindows) {
      throw UnsupportedError('Windows 无需手动导入内核，请使用「一键下载 / 更新内核」。');
    }
    final dir = await binDir();
    final target = '${dir.path}${Platform.pathSeparator}cloudflared';
    final src = File(sourcePath);
    if (!src.existsSync()) throw FileSystemException('源文件不存在', sourcePath);
    src.copySync(target);
    // Android 10+ 需要显式授予可执行权限
    try {
      await Process.run('/system/bin/chmod', ['700', target]);
    } catch (_) {}
    _binaryPath = target;
    await detectVersion();
    return target;
  }

  /// 版本号逐段比较：a 是否比 b 新（提取为静态方法便于单测）
  static bool isNewerVersion(String a, String b) {
    final pa = a.split('.').map(int.tryParse).toList();
    final pb = b.split('.').map(int.tryParse).toList();
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      final x = pa[i] ?? 0, y = pb[i] ?? 0;
      if (x != y) return x > y;
    }
    return pa.length > pb.length;
  }

  /// 查询 GitHub 最新发布的 cloudflared 版本号（失败返回 null）
  Future<String?> fetchLatestVersion() async {
    try {
      final res = await http
          .get(
            Uri.parse(
                'https://api.github.com/repos/cloudflare/cloudflared/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final tag = (jsonDecode(res.body) as Map<String, dynamic>)['tag_name']
              as String? ??
          '';
      final m = RegExp(r'(\d{4}\.\d+\.\d+|\d+\.\d+\.\d+)').firstMatch(tag);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// 检查内核更新：有新版本时返回最新版本号，否则返回 null
  Future<String?> checkUpdate() async {
    final latest = await fetchLatestVersion();
    if (latest == null || _version == null) return null;
    return isNewerVersion(latest, _version!) ? latest : null;
  }

  Future<bool> hasLoginCert() async {
    final home = await cloudflaredHome();
    return File('${home.path}${Platform.pathSeparator}cert.pem').existsSync();
  }
}
