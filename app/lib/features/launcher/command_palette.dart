import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/primitives.dart';
import '../../data/models.dart';

const _skills = [
  ('kickoff', 'Puxa o card, triage e encadeia o fluxo'),
  ('specify', 'Spec de negócio'),
  ('challenge-spec', 'Ataca a spec antes do plano'),
  ('plan', 'Plano técnico (ToT quando arriscado)'),
  ('tasks', 'Tasks com tier0, testes e escopo'),
  ('implement', 'Workflow smart-implement com a escada'),
  ('verify', 'G1 do ciclo + G2 QA'),
  ('complete', 'ADRs, lessons, routing, arquivo'),
  ('status', 'Estado do fluxo'),
  ('fix', 'Fluxo leve para bugs'),
  ('review', 'Review multi-agente de um PR'),
  ('adr', 'Gerencia ADRs do repo'),
];

Future<void> showCommandPalette(BuildContext context, Project project) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _CommandPalette(project: project),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.project});

  final Project project;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = _skills.where((s) => s.$1.contains(_query.toLowerCase())).toList();
    return Align(
      alignment: const Alignment(0, -0.5),
      child: Material(
        color: c.elevated,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Container(
          width: 560,
          decoration: BoxDecoration(
            border: Border.all(color: c.borderStrong),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Executar skill em ${widget.project.name}…',
                    hintStyle: TextStyle(color: c.textMuted),
                    prefixIcon: Icon(Icons.search, color: c.textMuted, size: 18),
                  ),
                ),
              ),
              Divider(height: 1, color: c.border),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(6),
                  children: [
                    for (final (i, s) in items.indexed)
                      Container(
                        decoration: BoxDecoration(
                          color: i == 0 ? c.hover : null,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        child: Row(
                          children: [
                            Mono('/${s.$1}', color: c.textPrimary, size: 13),
                            const SizedBox(width: 14),
                            Expanded(child: Muted(s.$2)),
                            if (i == 0) Mono('↵', color: c.textMuted),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.border)),
                ),
                child: const Muted('Roda no engine local · permissões aparecem na aba Sessões', size: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
