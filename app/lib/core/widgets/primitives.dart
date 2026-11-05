import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Top space kept clear on macOS: the window uses fullSizeContentView, so the traffic lights draw over
/// the first ~28pt of content.
const kTitleBarInset = 44.0;

class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, required this.color, this.mono = false, this.dot = true});

  final String label;
  final Color color;
  final bool mono;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                fontFamily: mono ? monoFamily : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TierChip extends StatelessWidget {
  const TierChip(this.tier, {super.key});

  final Tier tier;

  @override
  Widget build(BuildContext context) => Pill(label: tier.name, color: context.colors.tier(tier), mono: true);
}

class VerdictBadge extends StatelessWidget {
  const VerdictBadge(this.verdict, {super.key});

  final Verdict verdict;

  static String label(Verdict v) => switch (v) {
    Verdict.pass => 'pass',
    Verdict.fail => 'fail',
    Verdict.running => 'rodando',
    Verdict.blocked => 'bloqueado',
    Verdict.inconclusive => 'inconclusivo',
    Verdict.pending => 'pendente',
  };

  @override
  Widget build(BuildContext context) => Pill(label: label(verdict), color: context.colors.verdict(verdict));
}

class ComplexityTag extends StatelessWidget {
  const ComplexityTag(this.complexity, {super.key, this.risk = false});

  final Complexity complexity;
  final bool risk;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: c.borderStrong),
          ),
          child: Text(
            complexity.name.toUpperCase(),
            style: TextStyle(fontSize: 10, fontFamily: monoFamily, color: c.textSecondary, fontWeight: FontWeight.w600),
          ),
        ),
        if (risk) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: 'risco alto: tier0 subiu um degrau',
            child: Icon(Icons.bolt, size: 14, color: c.warn),
          ),
        ],
      ],
    );
  }
}

class Panel extends StatelessWidget {
  const Panel({super.key, this.title, this.trailing, required this.child, this.padding = const EdgeInsets.all(16)});

  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Container(
              height: 48,
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(title!, style: Theme.of(context).textTheme.titleMedium)),
                  ?trailing,
                ],
              ),
            ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class Mono extends StatelessWidget {
  const Mono(this.text, {super.key, this.color, this.size = 12});

  final String text;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontFamily: monoFamily, fontSize: size, color: color ?? context.colors.textSecondary),
  );
}

class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.size = 12});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: size, color: context.colors.textMuted),
  );
}

String formatTokens(int? n) => switch (n) {
  null => '—',
  >= 1000 => '${(n / 1000).toStringAsFixed(1)}k',
  _ => '$n',
};

/// Inline error under a toolbar; [onRetry] `null` disables "Tentar de novo".
class ErrorRetryRow extends StatelessWidget {
  const ErrorRetryRow(this.message, {super.key, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: c.fail),
          const SizedBox(width: 6),
          Flexible(
            child: Text(message, style: TextStyle(fontSize: 12, color: c.fail)),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onRetry,
            child: const Text('Tentar de novo', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Header of a fixed-width table; a `null` width is the flexible column and an empty label a spacer.
class TableHeaderRow extends StatelessWidget {
  const TableHeaderRow(this.columns, {super.key});

  final List<(String, double?)> columns;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget cell(String label, double? width) {
      final text = Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.textMuted),
      );
      return width == null ? Expanded(child: text) : SizedBox(width: width, child: text);
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(children: [for (final (label, width) in columns) cell(label, width)]),
    );
  }
}
