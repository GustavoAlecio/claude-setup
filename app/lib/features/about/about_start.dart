import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../app/engine_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primitives.dart';
import '../../core/widgets/readiness_checklist.dart';
import '../../engine/engine_supervisor.dart';

const _steps = [
  (
    'Crie uma org',
    'Uma org reúne os projetos de uma pasta (ex.: ~/development/cliente). Os repositórios dentro dela aparecem sozinhos; '
        'cada org pode ter a própria conta do GitHub, agente e permissões.',
  ),
  (
    'Abra um projeto',
    'Escolha o projeto na barra lateral. A aba Fluxo mostra o ciclo atual; Sessões, as conversas com o agente.',
  ),
  (
    'Comece pelo Kickoff',
    'Informe o ID de um card (Azure DevOps ou Linear) ou descreva o que precisa. O agente especifica, planeja, '
        'implementa e verifica em etapas.',
  ),
  (
    'Acompanhe e responda',
    'Quando o agente precisa de você — permissão para um comando, uma pergunta, um ciclo parado — aparece '
        '"aguardando você" no topo e um número na barra lateral. Clique para resolver.',
  ),
  (
    'Revise e entregue',
    'No fim do ciclo o app abre o PR. Em PRs e Para revisar você acompanha os seus e os que pedem a sua revisão.',
  ),
];

const _shortcuts = [
  ('⌘K', 'paleta do projeto: skills, nova conversa, kickoff'),
  ('⌘⇧K', 'nova atividade na org (fora de um projeto)'),
  ('⌘J', 'ir para a próxima pendência (permissão, pergunta, ciclo parado)'),
  ('⌘1 … ⌘9', 'trocar de org'),
  ('⌘,', 'Configurações'),
  ('⌘I', 'esta tela'),
  ('⌘↵', 'enviar a mensagem para a sessão'),
  ('⌘V', 'colar uma imagem na mensagem'),
];

const _glossary = [
  ('Ciclo', 'uma entrega, do kickoff ao PR.'),
  ('Etapa', 'cada passo do ciclo: kickoff, specify, challenge-spec, plan, tasks, implement, verify, complete.'),
  ('Gate', 'ponto em que o fluxo para e pede a sua aprovação antes de seguir.'),
  (
    'Piloto automático',
    'avança as etapas sem pedir aprovação, menos nos gates obrigatórios. Liga e desliga na barra lateral.',
  ),
  (
    'Permissões',
    'padrão pede tudo; aceitar edições deixa o agente editar e pergunta antes de comandos; bypass não pergunta nada.',
  ),
  ('Agente', 'quem executa: Claude Code ou Antigravity, escolhido por org em Configurações.'),
];

/// First tab of "Como funciona": how to use the app, not how it is built (that is under "Diagnóstico").
class AboutStart extends StatelessWidget {
  const AboutStart({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final engine = context.watch<EngineCubit>().state.data;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Desenvolva com agentes de IA em vários projetos', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                const Muted(
                  'O Claude Flow roda agentes nos seus repositórios e mostra o que cada um está fazendo, o que espera por '
                  'você e o que já está pronto, em todas as orgs.',
                  size: 13,
                ),
                const SizedBox(height: 20),
                const ReadinessChecklist(),
                const SizedBox(height: 24),
                const Muted('EM 5 PASSOS', size: 10),
                const SizedBox(height: 8),
                for (final (i, (title, text)) in _steps.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.15), shape: BoxShape.circle),
                          child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: c.accent)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(text, style: TextStyle(fontSize: 13, color: c.textSecondary, height: 1.4)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                const Muted('Atalhos', size: 11),
                const SizedBox(height: 8),
                for (final (keys, what) in _shortcuts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 110,
                          child: Text(
                            keys,
                            style: TextStyle(fontFamily: monoFamily, fontSize: 12, color: c.textPrimary),
                          ),
                        ),
                        Expanded(
                          child: Text(what, style: TextStyle(fontSize: 13, color: c.textSecondary)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                const Muted('Glossário', size: 10),
                const SizedBox(height: 8),
                for (final (term, meaning) in _glossary)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$term: ',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(
                            text: meaning,
                            style: TextStyle(color: c.textSecondary),
                          ),
                        ],
                      ),
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                const SizedBox(height: 20),
                Muted(switch (engine) {
                  EngineState(status: EngineStatus.ok, :final versionWarning) =>
                    'Serviço local rodando${versionWarning == null ? '' : ' · $versionWarning'}',
                  _ => 'Serviço local iniciando ou parado: veja o rodapé da barra lateral',
                }, size: 11),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
