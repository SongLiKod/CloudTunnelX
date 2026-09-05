import 'package:cloudtunnelx/core/models/log_entry.dart';
import 'package:cloudtunnelx/core/services/error_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('URL 拼写错误可被识别并给出修复方案', () {
    final (level, hint) = ErrorCatalog.match(
        'ERROR Origin Service url provided is not valid, url spelling may be wrong');
    expect(level, LogLevel.error);
    expect(hint, isNotNull);
    expect(hint, contains('URL'));
  });

  test('本地服务连接失败可被识别', () {
    final (level, hint) =
        ErrorCatalog.match('ERROR unable to reach the origin service');
    expect(level, LogLevel.error);
    expect(hint, isNotNull);
    expect(hint, contains('本地服务'));
  });

  test('DNS 解析失败可被识别', () {
    final (level, hint) = ErrorCatalog.match(
        'ERROR dial tcp: lookup app.example.com: no such host');
    expect(level, LogLevel.error);
    expect(hint, contains('解析'));
  });

  test('凭证/鉴权失败可被识别', () {
    final (level, hint) =
        ErrorCatalog.match('ERROR unauthorized: please login first, cert.pem missing');
    expect(level, LogLevel.error);
    expect(hint, contains('凭证'));
  });

  test('普通日志不误报', () {
    final (level, hint) = ErrorCatalog.match(
        'INFO Registered tunnel connection connIndex=0');
    expect(level, LogLevel.info);
    expect(hint, isNull);
  });
}
