import 'package:cloudtunnelx/core/models/cloudflare.dart';
import 'package:cloudtunnelx/core/models/protocol_type.dart';
import 'package:cloudtunnelx/core/models/tunnel_config.dart';
import 'package:cloudtunnelx/core/services/app_controller.dart';
import 'package:cloudtunnelx/core/services/binary_manager.dart';
import 'package:cloudtunnelx/core/services/validation_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ValidationService.rootDomainOf', () {
    test('二级域名取最后两段', () {
      expect(ValidationService.rootDomainOf('app.example.com'), 'example.com');
    });

    test('三级及以上子域名同样取最后两段', () {
      expect(ValidationService.rootDomainOf('a.b.app.example.com'),
          'example.com');
    });

    test('无子域名时返回全部', () {
      expect(ValidationService.rootDomainOf('example.com'), 'example.com');
    });
  });

  group('AppController.bestZoneFor', () {
    CfZone zone(String name) => CfZone(
        id: 'id-$name',
        name: name,
        status: 'active',
        paused: false,
        nameServers: 'ns1,ns2');

    test('精确匹配优先', () {
      final zones = [zone('example.com'), zone('app.example.com')];
      expect(AppController.bestZoneFor('app.example.com', zones)?.name,
          'app.example.com');
    });

    test('最长后缀匹配（优先更具体的 zone）', () {
      final zones = [zone('example.com'), zone('app.example.com')];
      expect(AppController.bestZoneFor('x.app.example.com', zones)?.name,
          'app.example.com');
    });

    test('无匹配返回 null', () {
      final zones = [zone('example.com')];
      expect(AppController.bestZoneFor('other.com', zones), isNull);
    });
  });

  group('BinaryManager.isNewerVersion', () {
    test('主版本号比较', () {
      expect(BinaryManager.isNewerVersion('2024.1.0', '2023.12.0'), isTrue);
      expect(BinaryManager.isNewerVersion('2023.12.0', '2024.1.0'), isFalse);
    });

    test('同版本非新版本', () {
      expect(BinaryManager.isNewerVersion('2024.1.0', '2024.1.0'), isFalse);
    });

    test('段数不同', () {
      expect(BinaryManager.isNewerVersion('2024.1', '2024.1.0'), isFalse);
    });
  });

  group('TunnelConfig JSON 往返（配置导入导出）', () {
    test('toJson/fromJson 保留关键字段', () {
      final c = TunnelConfig(
        id: 'abc123',
        mode: TunnelMode.named,
        name: '我的隧道',
        protocol: ProtocolType.tcp,
        localHost: '127.0.0.1',
        localPort: 3389,
        subdomain: 'rdp.example.com',
        tunnelUuid: 'uuid-1',
        autoRestore: true,
      );
      final restored = TunnelConfig.fromJson(c.toJson());
      expect(restored.id, c.id);
      expect(restored.mode, TunnelMode.named);
      expect(restored.name, c.name);
      expect(restored.protocol, ProtocolType.tcp);
      expect(restored.localPort, 3389);
      expect(restored.subdomain, 'rdp.example.com');
      expect(restored.tunnelUuid, 'uuid-1');
      expect(restored.autoRestore, isTrue);
    });

    test('缺失字段有缺省值', () {
      final c = TunnelConfig.fromJson({'id': 'x', 'name': 't'});
      expect(c.protocol, ProtocolType.http);
      expect(c.localHost, '127.0.0.1');
      expect(c.localPort, 80);
      expect(c.autoRestore, isFalse);
    });
  });
}