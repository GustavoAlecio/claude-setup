import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primitives.dart';
import '../../data/flow_aggregates.dart';
import '../../data/report_models.dart';

const _kBoxMaxWidth = 200.0;
const _kMinGap = 40.0;
const _kMaxGap = 120.0;
const _kRowGap = 16.0;
const _kPadding = 10.0;
const _kBorder = 1.5;
const _kLineGap = 4.0;
const _kMinStatusSize = 8.0;

/// Paths listed per node in the files panel; the rest is only counted.
const kGateMapFiles = 8;

const _label = (size: 12.5, height: 1.3);
const _note = (size: 11.5, height: 1.3);
const _status = (size: 11.0, height: 1.3);

Color mapToneColor(AppColors c, MapTone tone) => switch (tone) {
  MapTone.neutral => c.borderStrong,
  MapTone.accent => c.accent,
  MapTone.warn => c.warn,
  MapTone.fail => c.fail,
};

/// Ends of the line drawn from [from] to [to]: right border to left border when [to] lies in a column to the right,
/// else a straight line between the nearest borders.
(Offset, Offset) edgeSegment(Rect from, Rect to) {
  if (to.left >= from.right) return (from.centerRight, to.centerLeft);
  if (to.right <= from.left) return (from.centerLeft, to.centerRight);
  if (to.top >= from.bottom) return (from.bottomCenter, to.topCenter);
  return (from.topCenter, to.bottomCenter);
}

typedef MapEdgeLine = ({int index, MapEdge edge, Offset from, Offset to});

/// Every edge of the map but self edges, as straight lines with an arrow head at the target.
class GateMapEdgesPainter extends CustomPainter {
  GateMapEdgesPainter({required this.edges, required this.color});

  final List<MapEdgeLine> edges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final head = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final e in edges) {
      canvas.drawLine(e.from, e.to, line);
      final d = e.to - e.from;
      if (d.distance == 0) continue;
      final angle = math.atan2(d.dy, d.dx);
      const length = 7.0;
      const spread = 0.45;
      canvas.drawPath(
        Path()
          ..moveTo(e.to.dx, e.to.dy)
          ..lineTo(e.to.dx - length * math.cos(angle - spread), e.to.dy - length * math.sin(angle - spread))
          ..lineTo(e.to.dx - length * math.cos(angle + spread), e.to.dy - length * math.sin(angle + spread))
          ..close(),
        head,
      );
    }
  }

  @override
  bool shouldRepaint(GateMapEdgesPainter old) => old.edges != edges || old.color != color;
}

/// The nodes of a gate map as fixed-height boxes placed by [mapLayout], the edges in one paint, and, on a built map,
/// the files of the tapped node below the drawing.
class GateMapView extends StatefulWidget {
  const GateMapView({super.key, required this.map});

  final GateMap map;

  @override
  State<GateMapView> createState() => _GateMapViewState();
}

class _GateMapViewState extends State<GateMapView> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final map = widget.map;
    final open = map.built ? map.nodes.where((n) => n.id == _open && n.files.isNotEmpty).firstOrNull : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, constraints) => _drawing(context, constraints.maxWidth)),
        if (open != null) ...[const SizedBox(height: 12), _Files(node: open)],
      ],
    );
  }

  Widget _drawing(BuildContext context, double width) {
    final c = context.colors;
    final map = widget.map;
    final scaler = MediaQuery.textScalerOf(context);
    double line(({double size, double height}) s) => scaler.scale(s.size) * s.height;

    final layout = mapLayout(map.nodes, map.edges);
    final columns = layout.values.fold(0, (m, p) => math.max(m, p.col + 1));
    final rows = layout.values.fold(0, (m, p) => math.max(m, p.row + 1));
    final boxWidth = math.min(_kBoxMaxWidth, (width - _kMinGap * (columns - 1)) / columns);
    final gap = columns > 1 ? ((width - boxWidth * columns) / (columns - 1)).clamp(_kMinGap, _kMaxGap) : _kMinGap;
    final notes = map.nodes.any((n) => n.note != null && n.note!.isNotEmpty);
    final counts = map.built && map.nodes.any((n) => n.files.isNotEmpty);
    final statusLines = map.built ? 2 : 1;
    // Fixed height from the same line metrics the forced struts use, so every box fits the tallest content.
    final boxHeight =
        2 * (_kPadding + _kBorder) +
        2 * line(_label) +
        (notes ? _kLineGap + 2 * line(_note) : 0) +
        _kLineGap +
        statusLines * line(_status) +
        (counts ? line(_status) : 0) +
        2;

    final rects = {
      for (final MapEntry(key: id, value: p) in layout.entries)
        id: Rect.fromLTWH(p.col * (boxWidth + gap), p.row * (boxHeight + _kRowGap), boxWidth, boxHeight),
    };
    final edges = <MapEdgeLine>[
      for (final (i, e) in map.edges.indexed)
        if (e.from != e.to)
          if ((rects[e.from], rects[e.to]) case (final from?, final to?))
            (() {
              final (a, b) = edgeSegment(from, to);
              return (index: i, edge: e, from: a, to: b);
            })(),
    ];
    return SizedBox(
      height: rows * (boxHeight + _kRowGap) - _kRowGap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: GateMapEdgesPainter(edges: edges, color: c.textMuted),
            ),
          ),
          for (final n in map.nodes)
            if (rects[n.id] case final rect?)
              Positioned.fromRect(
                rect: rect,
                child: _Node(
                  node: n,
                  notes: notes,
                  counts: counts,
                  statusLines: statusLines,
                  onTap: map.built && n.files.isNotEmpty
                      ? () => setState(() => _open = _open == n.id ? null : n.id)
                      : null,
                ),
              ),
        ],
      ),
    );
  }
}

StrutStyle _strut(({double size, double height}) s) =>
    StrutStyle(fontSize: s.size, height: s.height, forceStrutHeight: true);

/// Largest size up to the status size at which [word] fits in [lines] lines of [width]; the line height stays the
/// strut's, so the fixed box height holds.
double _fittingStatusSize(BuildContext context, String word, double width, int lines) {
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  final base = DefaultTextStyle.of(context).style;
  for (var size = _status.size; size > _kMinStatusSize; size -= 0.5) {
    final painter = TextPainter(
      text: TextSpan(
        text: word,
        style: base.merge(TextStyle(fontSize: size, height: _status.height)),
      ),
      textDirection: direction,
      textScaler: scaler,
      maxLines: lines,
    )..layout(maxWidth: width);
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    if (fits) return size;
  }
  return _kMinStatusSize;
}

class _Node extends StatelessWidget {
  const _Node({
    required this.node,
    required this.notes,
    required this.counts,
    required this.statusLines,
    required this.onTap,
  });

  final MapNode node;

  /// Some node of the map has a note: every box keeps room for two lines of it.
  final bool notes;

  /// Some node of the built map has files: every box keeps a line for the count.
  final bool counts;

  /// Lines kept for the state word: the longest built word needs two in a four-column map.
  final int statusLines;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final look = mapNodeLook(node);
    final note = node.note;
    final word = look.word;
    final toneColor = look.tone == MapTone.neutral ? c.textMuted : mapToneColor(c, look.tone);
    final box = Container(
      key: ValueKey('gate-map-node-${node.id}'),
      padding: const EdgeInsets.all(_kPadding),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: mapToneColor(c, look.tone), width: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            node.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            strutStyle: _strut(_label),
            style: TextStyle(
              fontSize: _label.size,
              height: _label.height,
              fontWeight: FontWeight.w600,
              color: look.muted ? c.textMuted : c.textPrimary,
            ),
          ),
          if (notes) ...[
            const SizedBox(height: _kLineGap),
            Text(
              note ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              strutStyle: _strut(_note),
              style: TextStyle(fontSize: _note.size, height: _note.height, color: c.textSecondary),
            ),
          ],
          const Spacer(),
          if (word != null)
            LayoutBuilder(
              builder: (context, constraints) {
                final size = _fittingStatusSize(context, word, constraints.maxWidth, statusLines);
                return Text(
                  word,
                  key: ValueKey('gate-map-node-${node.id}-state'),
                  maxLines: statusLines,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: _strut(_status),
                  style: TextStyle(fontSize: size, height: _status.height, color: toneColor),
                );
              },
            ),
          if (counts && node.files.isNotEmpty)
            Text(
              countLabel(node.files.length, 'arquivo'),
              key: ValueKey('gate-map-node-${node.id}-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              strutStyle: _strut(_status),
              style: TextStyle(fontSize: _status.size, height: _status.height, color: c.textMuted),
            ),
        ],
      ),
    );
    final onTap = this.onTap;
    if (onTap == null) return box;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: box),
    );
  }
}

/// The labeled edges of [map], one line each, since the gap between columns is too narrow to write on the line.
class GateMapEdgeList extends StatelessWidget {
  const GateMapEdgeList({super.key, required this.map});

  final GateMap map;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final names = {for (final n in map.nodes) n.id: n.label};
    final rows = [
      for (final (i, e) in map.edges.indexed)
        if (e.label case final label? when label.isNotEmpty)
          if ((names[e.from], names[e.to]) case (final from?, final to?)) (i, '$from → $to: $label'),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('gate-map-edges'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Muted('Ligações', size: 11),
        const SizedBox(height: 6),
        for (final (i, text) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              text,
              key: ValueKey('gate-map-edge-$i-label'),
              style: TextStyle(fontSize: 12.5, height: 1.4, color: c.textSecondary),
            ),
          ),
      ],
    );
  }
}

class _Files extends StatelessWidget {
  const _Files({required this.node});

  final MapNode node;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rest = node.files.length - kGateMapFiles;
    return Container(
      key: const ValueKey('gate-map-files'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            node.label,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.textPrimary),
          ),
          const SizedBox(height: 6),
          for (final path in node.files.take(kGateMapFiles))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.textSecondary),
              ),
            ),
          if (rest > 0) ...[const SizedBox(height: 4), Muted('mais ${countLabel(rest, 'arquivo')}', size: 11.5)],
        ],
      ),
    );
  }
}
