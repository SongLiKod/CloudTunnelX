/// 隧道穿透协议类型（对齐需求文档 1.3：支持 HTTP/HTTPS/WebSocket/TCP）
enum ProtocolType {
  http('HTTP', '七层 · 网页/接口'),
  https('HTTPS', '七层 · 加密网页'),
  websocket('WebSocket', '七层 · 长连接'),
  tcp('TCP', '四层 · SSH/RDP/数据库');

  final String label;
  final String desc;
  const ProtocolType(this.label, this.desc);

  /// 是否为七层网页协议（HTTP/HTTPS/WS，可绑定自有子域名）
  bool get isWeb => this != ProtocolType.tcp;

  /// cloudflared --url 中使用的 scheme
  String get scheme => switch (this) {
        ProtocolType.http => 'http',
        ProtocolType.https => 'https',
        ProtocolType.websocket => 'ws',
        ProtocolType.tcp => 'tcp',
      };

  static ProtocolType fromName(String? name) => ProtocolType.values
      .firstWhere((e) => e.name == name, orElse: () => ProtocolType.http);
}
