import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/cloudflare.dart';

/// Cloudflare API 封装（域名与 DNS 记录管理，替代网页端操作）
/// 文档：https://developers.cloudflare.com/api/
/// 所需权限：Zone:Read、DNS:Edit（API Token，推荐）或全局 API Key
class CloudflareService extends ChangeNotifier {
  static const _base = 'https://api.cloudflare.com/client/v4';

  String? _apiToken;
  bool _testing = false;
  String? _lastError;
  String? _accountId;

  String? get apiToken => _apiToken;
  bool get configured => (_apiToken ?? '').trim().isNotEmpty;
  bool get testing => _testing;
  String? get lastError => _lastError;

  void setToken(String? token) {
    _apiToken = (token ?? '').trim().isEmpty ? null : token!.trim();
    notifyListeners();
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_apiToken',
        'Content-Type': 'application/json',
      };

  /// 校验 Token 有效性（获取账户信息）
  Future<bool> verifyToken() async {
    if (!configured) return false;
    _testing = true;
    _lastError = null;
    notifyListeners();
    try {
      final res = await http
          .get(Uri.parse('$_base/user/tokens/verify'), headers: _headers)
          .timeout(const Duration(seconds: 10));
      final ok = _ok(res);
      if (!ok) _lastError = _message(res);
      return ok;
    } catch (e) {
      _lastError = '网络异常：$e';
      return false;
    } finally {
      _testing = false;
      notifyListeners();
    }
  }

  /// 列出账户下所有托管域名（Zone）
  Future<List<CfZone>> listZones() async {
    if (!configured) throw StateError('未配置 Cloudflare API Token');
    final zones = <CfZone>[];
    var page = 1;
    while (true) {
      final res = await http.get(
        Uri.parse('$_base/zones?per_page=50&page=$page&status=active'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      if (!_ok(res)) throw ApiException(_message(res));
      final body = jsonDecode(res.body);
      final result = body['result'] as List;
      final zoneList =
          result.map((j) => CfZone.fromJson(j as Map<String, dynamic>)).toList();
      zones.addAll(zoneList);
      // 缓存账户 ID（隧道连接状态查询需要）
      for (final z in zoneList) {
        if (z.accountId != null) {
          _accountId = z.accountId;
          break;
        }
      }
      final info = body['result_info'] as Map;
      final totalPages = info['total_pages'] as int;
      if (page >= totalPages) break;
      page++;
    }
    return zones;
  }

  /// 查询账户下命名隧道的连接状态（边缘节点连接数）
  /// uuid 为空时返回全部隧道
  Future<List<CfTunnelInfo>> listTunnels({String? uuid}) async {
    if (!configured) throw StateError('未配置 Cloudflare API Token');
    final accountId = _accountId;
    if (accountId == null) {
      // 尚未拉取过 Zone，先取一次以获得账户 ID
      await listZones();
    }
    if (_accountId == null) throw ApiException('无法获取 Cloudflare 账户 ID');
    final q = uuid != null ? '&uuid=$uuid' : '';
    final res = await http.get(
      Uri.parse('$_base/accounts/$_accountId/tunnels?is_deleted=false$q'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (!_ok(res)) throw ApiException(_message(res));
    final body = jsonDecode(res.body);
    final result = (body['result'] as List?) ?? [];
    return result
        .map((j) => CfTunnelInfo.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// 列出某域名下的 DNS 记录
  Future<List<CfDnsRecord>> listDnsRecords(String zoneId, {String? type}) async {
    if (!configured) throw StateError('未配置 Cloudflare API Token');
    final records = <CfDnsRecord>[];
    var page = 1;
    while (true) {
      final typeQ = type != null ? '&type=$type' : '';
      final res = await http.get(
        Uri.parse(
            '$_base/zones/$zoneId/dns_records?per_page=100&page=$page$typeQ'),
        headers: _headers,
      ).timeout(const Duration(seconds: 15));
      if (!_ok(res)) throw ApiException(_message(res));
      final body = jsonDecode(res.body);
      final result = body['result'] as List;
      records.addAll(result
          .map((j) => CfDnsRecord.fromJson(j as Map<String, dynamic>, zoneId)));
      final info = body['result_info'] as Map;
      final totalPages = info['total_pages'] as int;
      if (page >= totalPages) break;
      page++;
    }
    return records;
  }

  /// 创建 DNS 记录（常用于把隧道绑定到子域名）
  Future<CfDnsRecord> createDnsRecord({
    required String zoneId,
    required String type,
    required String name,
    required String content,
    bool proxied = true,
    int ttl = 1,
    String? comment,
  }) async {
    if (!configured) throw StateError('未配置 Cloudflare API Token');
    final payload = <String, dynamic>{
      'type': type,
      'name': name,
      'content': content,
      'proxied': proxied,
      'ttl': ttl,
    };
    if (comment != null) payload['comment'] = comment;
    final res = await http.post(
      Uri.parse('$_base/zones/$zoneId/dns_records'),
      headers: _headers,
      body: jsonEncode(payload),
    ).timeout(const Duration(seconds: 15));
    if (!_ok(res)) throw ApiException(_message(res));
    final body = jsonDecode(res.body);
    return CfDnsRecord.fromJson(body['result'] as Map<String, dynamic>, zoneId);
  }

  /// 更新 DNS 记录
  Future<CfDnsRecord> updateDnsRecord({
    required String zoneId,
    required String recordId,
    String? name,
    String? content,
    bool? proxied,
    int? ttl,
  }) async {
    if (!configured) throw StateError('未配置 Cloudflare API Token');
    final payload = <String, dynamic>{};
    if (name != null) payload['name'] = name;
    if (content != null) payload['content'] = content;
    if (proxied != null) payload['proxied'] = proxied;
    if (ttl != null) payload['ttl'] = ttl;
    final res = await http.patch(
      Uri.parse('$_base/zones/$zoneId/dns_records/$recordId'),
      headers: _headers,
      body: jsonEncode(payload),
    ).timeout(const Duration(seconds: 15));
    if (!_ok(res)) throw ApiException(_message(res));
    final body = jsonDecode(res.body);
    return CfDnsRecord.fromJson(body['result'] as Map<String, dynamic>, zoneId);
  }

  /// 删除 DNS 记录
  Future<void> deleteDnsRecord(String zoneId, String recordId) async {
    if (!configured) throw StateError('未配置 Cloudflare API Token');
    final res = await http.delete(
      Uri.parse('$_base/zones/$zoneId/dns_records/$recordId'),
      headers: _headers,
    ).timeout(const Duration(seconds: 15));
    if (!_ok(res)) throw ApiException(_message(res));
  }

  bool _ok(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final body = jsonDecode(res.body);
        return body['success'] == true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  String _message(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      final errors = (body['errors'] as List?) ?? [];
      if (errors.isNotEmpty) {
        return (errors.first as Map)['message'] as String? ?? res.body;
      }
      return body['messages']?.toString() ?? res.body;
    } catch (_) {
      return res.body;
    }
  }
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => 'Cloudflare API 错误：$message';
}
