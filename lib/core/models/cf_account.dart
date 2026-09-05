/// Cloudflare 账号（API Token + 显示名称），用于域名管理的多 Token 支持
class CfAccount {
  final String id;
  String name;

  CfAccount({required this.id, required this.name});

  factory CfAccount.fromJson(Map<String, dynamic> j) => CfAccount(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}