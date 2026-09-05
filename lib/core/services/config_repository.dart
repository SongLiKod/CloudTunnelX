import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/tunnel_config.dart';

/// 配置持久化（技术文档 2.4：Hive 轻量跨端存储，保存隧道配置与用户参数）
class ConfigRepository extends ChangeNotifier {
  static const _tunnelBox = 'tunnels';
  static const _settingBox = 'settings';

  Box? _tunnels;
  Box? _settings;

  Future<void> init() async {
    await Hive.initFlutter('cloudtunnelx_data');
    _tunnels = await Hive.openBox(_tunnelBox);
    _settings = await Hive.openBox(_settingBox);
    notifyListeners();
  }

  bool get ready => _tunnels != null && _settings != null;

  // ---------- 隧道配置 ----------
  List<TunnelConfig> loadTunnels() {
    if (_tunnels == null) return [];
    final list = <TunnelConfig>[];
    for (final key in _tunnels!.keys) {
      try {
        final raw = _tunnels!.get(key);
        if (raw is Map) {
          list.add(TunnelConfig.fromJson(Map<String, dynamic>.from(raw)));
        }
      } catch (_) {}
    }
    list.sort((a, b) => b.createdAt - a.createdAt);
    return list;
  }

  Future<void> saveTunnel(TunnelConfig c) async {
    await _tunnels?.put(c.id, c.toJson());
    notifyListeners();
  }

  Future<void> deleteTunnel(String id) async {
    await _tunnels?.delete(id);
    notifyListeners();
  }

  // ---------- 通用设置 ----------
  T? getSetting<T>(String key) => _settings?.get(key) as T?;

  Future<void> setSetting(String key, Object? value) async {
    await _settings?.put(key, value);
    notifyListeners();
  }
}
