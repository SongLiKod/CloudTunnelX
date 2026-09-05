import 'dart:io';

/// Windows 开机自启（技术文档 4.2：通过注册表 HKCU Run 键实现，普通用户权限即可）
class AutostartService {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'CloudTunnelX';

  bool get supported => Platform.isWindows;

  Future<bool> isEnabled() async {
    if (!supported) return false;
    final res = await Process.run(
        'reg', ['query', _runKey, '/v', _valueName],
        runInShell: true);
    return res.exitCode == 0 &&
        res.stdout.toString().contains(_valueName);
  }

  Future<void> setEnabled(bool enable) async {
    if (!supported) return;
    if (enable) {
      final exe = Platform.resolvedExecutable;
      await Process.run('reg', [
        'add', _runKey, '/v', _valueName, '/t', 'REG_SZ', '/d', '"$exe" --autostart', '/f'
      ], runInShell: true);
    } else {
      await Process.run('reg', ['delete', _runKey, '/v', _valueName, '/f'],
          runInShell: true);
    }
  }
}
