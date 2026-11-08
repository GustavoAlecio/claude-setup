import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/sessions_repository.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A ```` ```mermaid ```` block drawn by the engine (`POST /api/mermaid`); the source stays one tap away. Without
/// an engine, while rendering, or on a syntax error the block shows the source, with the error under it.
class MermaidBlock extends StatefulWidget {
  const MermaidBlock(this.code, {super.key});

  final String code;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  Future<Uint8List>? _png;
  bool? _dark;
  bool _showCode = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark != _dark) _render(dark);
  }

  @override
  void didUpdateWidget(MermaidBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) _render(_dark ?? true);
  }

  void _render(bool dark) {
    _dark = dark;
    final png = SessionsScope.maybeOf(context)?.renderMermaid(widget.code, dark: dark);
    // Only logs: the FutureBuilder still gets the original error and falls back to the source.
    unawaited(
      png?.then<void>(
        (_) {},
        onError: (Object e, StackTrace st) =>
            log('mermaid not rendered', name: 'MermaidBlock', error: e, stackTrace: st),
      ),
    );
    _png = png;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.elevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      child: FutureBuilder<Uint8List>(
        future: _png,
        builder: (context, snapshot) {
          final png = snapshot.data;
          final drawn = png != null && png.isNotEmpty;
          final error = snapshot.error;
          final waiting = _png != null && snapshot.connectionState != ConnectionState.done;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 4, 0),
                child: Row(
                  children: [
                    Text(
                      'mermaid',
                      style: TextStyle(fontFamily: monoFamily, fontSize: 11, color: c.textMuted),
                    ),
                    if (waiting) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted),
                      ),
                    ],
                    const Spacer(),
                    if (drawn)
                      TextButton(
                        key: const ValueKey('mermaid-toggle'),
                        style: TextButton.styleFrom(
                          foregroundColor: c.textSecondary,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => setState(() => _showCode = !_showCode),
                        child: Text(_showCode ? 'diagrama' : 'código', style: const TextStyle(fontSize: 11)),
                      )
                    else
                      const SizedBox(height: 32),
                  ],
                ),
              ),
              if (drawn && !_showCode)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                  // Rendered at 2x: scale 2 keeps it at the size mermaid laid it out.
                  child: Image.memory(png, scale: 2, filterQuality: FilterQuality.medium, gaplessPlayback: true),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                  child: Text(
                    widget.code,
                    style: TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.45, color: c.textPrimary),
                  ),
                ),
              if (error is SessionsException && error.statusCode == 422)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  child: Text('diagrama inválido: ${error.message}', style: TextStyle(fontSize: 11, color: c.warn)),
                ),
            ],
          );
        },
      ),
    );
  }
}
