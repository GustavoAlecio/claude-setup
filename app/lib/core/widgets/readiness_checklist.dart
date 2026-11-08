import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/engine_cubit.dart';
import '../../data/session_models.dart';
import '../../data/sessions_repository.dart';
import '../../engine/engine_supervisor.dart';
import '../theme/app_colors.dart';
import 'primitives.dart';

/// First-use checklist: the local engine, Claude Code and `gh` logged in. Checked once the engine is up; "verificar
/// de novo" re-asks past the engine's cache after the user logs in on a terminal.
class ReadinessChecklist extends StatefulWidget {
  const ReadinessChecklist({super.key});

  @override
  State<ReadinessChecklist> createState() => _ReadinessChecklistState();
}

class _ReadinessChecklistState extends State<ReadinessChecklist> {
  Uri? _checkedFor;
  Future<Readiness>? _readiness;

  void _check({bool fresh = false}) {
    final future = SessionsScope.of(context).readiness(fresh: fresh);
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object e, StackTrace st) =>
            log('readiness failed', name: 'ReadinessChecklist', error: e, stackTrace: st),
      ),
    );
    setState(() {
      _readiness = future;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final engine = context.watch<EngineCubit>().state.data ?? const EngineState.starting();
    final endpoint = engine.endpoint;
    if (endpoint != null && endpoint != _checkedFor) {
      _checkedFor = endpoint;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _check();
      });
    }
    return Container(
      key: const ValueKey('readiness-checklist'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: FutureBuilder<Readiness>(
        future: _readiness,
        builder: (context, snapshot) {
          final r = snapshot.data;
          final waiting = engine.status == EngineStatus.ok && snapshot.connectionState != ConnectionState.done;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(child: Muted('Antes de começar', size: 11)),
                  if (r != null)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: c.accent, visualDensity: VisualDensity.compact),
                      onPressed: () => _check(fresh: true),
                      child: const Text('verificar de novo', style: TextStyle(fontSize: 11)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              _Line(
                ok: engine.status == EngineStatus.ok,
                pending: engine.status == EngineStatus.starting,
                title: 'Serviço local do app',
                detail: switch (engine.status) {
                  EngineStatus.ok => 'rodando',
                  EngineStatus.starting => 'iniciando…',
                  EngineStatus.stopped => engine.error ?? 'parado: veja o rodapé da barra lateral',
                },
              ),
              _Line(
                ok: r?.claudeOk ?? false,
                pending: r == null && (waiting || engine.status == EngineStatus.starting),
                title: 'Claude Code',
                detail: r == null
                    ? (snapshot.hasError ? 'não deu para verificar' : 'verificando…')
                    : r.claudeOk
                    ? [r.claudeAccount, if (r.claudePlan case final plan?) 'plano $plan'].nonNulls.join(' · ')
                    : 'sem login: rode claude no Terminal e entre na sua conta',
              ),
              _Line(
                ok: r?.ghOk ?? false,
                pending: r == null && (waiting || engine.status == EngineStatus.starting),
                title: 'GitHub (gh)',
                detail: r == null
                    ? (snapshot.hasError ? 'não deu para verificar' : 'verificando…')
                    : r.ghOk
                    ? 'conta ${r.ghActive ?? 'logada'}'
                    : 'sem login: rode gh auth login no Terminal (PRs e revisões dependem dele)',
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.ok, required this.pending, required this.title, required this.detail});

  final bool ok;
  final bool pending;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: pending
                ? SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: c.textMuted),
                  )
                : Icon(ok ? Icons.check_circle : Icons.error_outline, size: 14, color: ok ? c.pass : c.warn),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 150,
            child: Text(title, style: TextStyle(fontSize: 12, color: c.textPrimary)),
          ),
          Expanded(
            child: Text(detail, style: TextStyle(fontSize: 12, color: ok || pending ? c.textSecondary : c.warn)),
          ),
        ],
      ),
    );
  }
}
