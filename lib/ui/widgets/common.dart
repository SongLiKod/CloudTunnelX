import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/log_entry.dart';
import '../../core/models/protocol_type.dart';
import '../../core/models/tunnel_status.dart';

/// 状态徽章（运行中/已停止/异常…）
class StatusChip extends StatelessWidget {
  final TunnelStatus status;
  const StatusChip({super.key, required this.status});

  Color get _color => switch (status) {
        TunnelStatus.running => Colors.green.shade400,
        TunnelStatus.starting => Colors.blue.shade400,
        TunnelStatus.reconnecting => Colors.orange.shade400,
        TunnelStatus.error => Colors.red.shade400,
        TunnelStatus.stopped => Colors.grey.shade500,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == TunnelStatus.running ||
              status == TunnelStatus.starting ||
              status == TunnelStatus.reconnecting)
            const _PulsingDot(),
          Text(status.label,
              style: TextStyle(color: _color, fontSize: 12, height: 1.4)),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
        child: Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.only(right: 6),
          decoration: const BoxDecoration(
              color: Colors.white, shape: BoxShape.circle),
        ),
      );
}

/// 协议标签
class ProtocolChip extends StatelessWidget {
  final ProtocolType protocol;
  const ProtocolChip({super.key, required this.protocol});

  @override
  Widget build(BuildContext context) {
    final isTcp = protocol == ProtocolType.tcp;
    final color = isTcp ? Colors.deepPurple.shade300 : Colors.teal.shade300;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(protocol.label,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// 总览统计卡片
class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  const StatCard(
      {super.key, required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(title,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 10),
            Text(value,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// 一键复制组件
class CopyButton extends StatelessWidget {
  final String value;
  final String? tooltip;
  const CopyButton({super.key, required this.value, this.tooltip});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip ?? '复制',
      icon: const Icon(Icons.copy_rounded, size: 18),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)));
        }
      },
    );
  }
}

/// 异常提醒弹窗（需求 3.3：展示报错原因与修复方案）
Future<void> showFixDialog(BuildContext context,
    {required String title, required String cause, required String fix}) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(children: [
        Icon(Icons.build_circle_outlined,
            color: Theme.of(ctx).colorScheme.error),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 17))),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('报错原因', style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(ctx).colorScheme.primary)),
          const SizedBox(height: 4),
          SelectableText(cause),
          const SizedBox(height: 14),
          Text('修复方案', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.green.shade400)),
          const SizedBox(height: 4),
          SelectableText(fix),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
      ],
    ),
  );
}

/// 日志级别图标/颜色辅助
Color logColor(LogLevel level) => switch (level) {
      LogLevel.error => Colors.red.shade300,
      LogLevel.warn => Colors.orange.shade300,
      LogLevel.success => Colors.green.shade300,
      LogLevel.info => Colors.blueGrey.shade200,
    };

IconData logIcon(LogLevel level) => switch (level) {
      LogLevel.error => Icons.error_outline_rounded,
      LogLevel.warn => Icons.warning_amber_rounded,
      LogLevel.success => Icons.check_circle_outline_rounded,
      LogLevel.info => Icons.info_outline_rounded,
    };

/// 流量历史迷你曲线（CustomPaint 绘制，无第三方依赖）
class TrafficSparkline extends StatelessWidget {
  final List<TrafficPoint> points;
  final double height;
  const TrafficSparkline({super.key, required this.points, this.height = 48});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('流量速率（近 ${points.length * 5}s）',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        SizedBox(
          height: height,
          child: CustomPaint(
            size: Size(double.infinity, height),
            painter: _SparklinePainter(points, scheme.primary),
          ),
        ),
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<TrafficPoint> points;
  final Color color;
  _SparklinePainter(this.points, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0 || size.height <= 0) return;
    final maxB = points.map((p) => p.bytes).fold<int>(1, (a, b) => b > a ? b : a);
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0.02)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    double x(int i) => points.length == 1
        ? 0
        : i * size.width / (points.length - 1);
    double y(int v) => size.height - (v / maxB) * (size.height - 4) - 2;

    final path = Path()..moveTo(x(0), y(points[0].bytes));
    for (var i = 1; i < points.length; i++) {
      path.lineTo(x(i), y(points[i].bytes));
    }
    canvas.drawPath(path, line);

    final fillPath = Path.from(path)
      ..lineTo(x(points.length - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(fillPath, fill);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.points != points;
}
