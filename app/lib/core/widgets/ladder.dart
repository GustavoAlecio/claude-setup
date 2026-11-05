import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// One lane per tier, one column per attempt: a task that escalates reads as a staircase.
class Ladder extends StatelessWidget {
  const Ladder({super.key, required this.task, this.slots = 5, this.laneHeight = 11, this.labels = true});

  final TaskRun task;
  final int slots;
  final double laneHeight;
  final bool labels;

  static const columnWidth = 26.0;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: task.attempts.isEmpty
          ? 'sem tentativas · tier0 ${task.tier0.name}'
          : task.attempts.map((a) => '${a.label} ${a.tier.name} ${a.verdict.name}').join('  →  '),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (labels)
            Column(
              children: [
                for (final t in Tier.values.reversed)
                  SizedBox(
                    width: 12,
                    height: laneHeight,
                    child: Text(
                      t.name[0],
                      style: TextStyle(
                        fontSize: laneHeight - 2,
                        height: 1,
                        fontFamily: monoFamily,
                        color: t == task.tier ? c.tier(t) : c.textMuted,
                        fontWeight: t == task.tier ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
              ],
            ),
          CustomPaint(
            size: Size(columnWidth * slots, laneHeight * Tier.values.length),
            painter: _LadderPainter(task: task, colors: c, laneHeight: laneHeight),
          ),
        ],
      ),
    );
  }
}

class _LadderPainter extends CustomPainter {
  _LadderPainter({required this.task, required this.colors, required this.laneHeight});

  final TaskRun task;
  final AppColors colors;
  final double laneHeight;

  double _y(Tier t) => (Tier.values.length - 1 - t.index) * laneHeight + laneHeight / 2;
  double _x(int i) => i * Ladder.columnWidth + Ladder.columnWidth / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = colors.border
      ..strokeWidth = 1;
    for (final t in Tier.values) {
      canvas.drawLine(Offset(0, _y(t)), Offset(size.width, _y(t)), guide);
    }

    if (task.attempts.isEmpty) {
      final p = Paint()
        ..color = colors.idle
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(Offset(_x(0), _y(task.tier0)), 4, p);
      return;
    }

    final path = Path();
    for (var i = 0; i < task.attempts.length; i++) {
      final a = task.attempts[i];
      final pt = Offset(_x(i), _y(a.tier));
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        final prev = Offset(_x(i - 1), _y(task.attempts[i - 1].tier));
        path.lineTo(pt.dx, prev.dy);
        path.lineTo(pt.dx, pt.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.borderStrong
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    for (var i = 0; i < task.attempts.length; i++) {
      final a = task.attempts[i];
      final center = Offset(_x(i), _y(a.tier));
      final col = colors.verdict(a.verdict);
      canvas.drawCircle(center, 4, Paint()..color = colors.tier(a.tier));
      if (a.verdict != Verdict.pass) {
        canvas.drawCircle(
          center,
          6.5,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    if (task.status == Verdict.blocked) {
      final last = Offset(_x(task.attempts.length - 1), _y(task.attempts.last.tier));
      final x = Paint()
        ..color = colors.fail
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      final o = last + const Offset(12, 0);
      canvas.drawLine(o + const Offset(-3, -3), o + const Offset(3, 3), x);
      canvas.drawLine(o + const Offset(-3, 3), o + const Offset(3, -3), x);
    }
  }

  @override
  bool shouldRepaint(_LadderPainter old) => old.task != task || old.colors != colors;
}
