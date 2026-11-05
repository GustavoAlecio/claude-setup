# ADR Index

> Gerado por `adr-index.py reindex`. Não editar à mão.

| ID | Título | Status | Affects | Supersedes | Superseded by |
|---|---|---|---|---|---|
| [[0001-watcher-unico-com-classify-puro\|0001]] | Fonte reativa do app com um único watcher e classificação pura | superseded | `app/lib/data/file_flow_repository.dart`<br>`app/lib/data/workflow_parser.dart` |  | 0009 |
| [[0002-parser-puro-separado-do-io\|0002]] | Parser puro separado do IO e modelos escritos à mão | accepted | `app/lib/data/workflow_parser.dart`<br>`app/lib/data/models.dart` |  |  |
| [[0003-stream-cubit-generico\|0003]] | Estado de UI com StreamCubit genérico e router que não lê o repositório | accepted | `app/lib/core/bloc/**`<br>`app/lib/app/**`<br>`app/lib/features/**` |  |  |
| [[0004-fixtures-geradas-pelo-persist\|0004]] | Fixtures geradas pelo persist real com checagem de drift | accepted | `app/test/fixtures/**`<br>`tests/run.sh` |  |  |
| [[0005-app-macos-sem-sandbox\|0005]] | App macOS sem App Sandbox | accepted | `app/macos/Runner/*.entitlements` |  |  |
| [[0006-testes-de-workflow-fora-do-g0\|0006]] | Testes de workflow e scripts fora do G0 | superseded | `tests/**`<br>`workflows/**`<br>`bin/**` |  | 0008 |
| [[0007-engine-node-processo-filho\|0007]] | Engine Node como processo filho com encerramento por stdin-EOF | accepted | `engine/**`<br>`app/lib/engine/**` |  |  |
| [[0008-testes-fora-do-g0-incluem-engine\|0008]] | Testes de workflow, scripts e engine fora do G0 | accepted | `tests/**`<br>`workflows/**`<br>`bin/**`<br>`engine/**` | 0006 |  |
| [[0009-watcher-unico-com-config-reativa\|0009]] | Watcher único com classificação pura, incluindo a config do dashboard | accepted | `app/lib/data/file_flow_repository.dart`<br>`app/lib/data/workflow_parser.dart`<br>`app/lib/data/orgs.dart` | 0001 |  |
| [[0010-escrita-atomica-do-dashboard-json\|0010]] | Escrita do .dashboard.json por mutação pura sobre o mapa cru, atômica e serializada | accepted | `app/lib/data/config_mutations.dart`<br>`app/lib/data/dashboard_config_repository.dart`<br>`app/lib/data/flow_repository.dart`<br>`app/lib/features/settings/**` |  |  |
| [[0011-resolucao-de-path-de-projeto\|0011]] | Path de projeto com a mesma precedência e desempate por profundidade no app e no engine | accepted | `app/lib/data/orgs.dart`<br>`app/lib/data/project_scan.dart`<br>`engine/cwd.mjs` |  |  |
| [[0012-contrato-do-comando-kickoff-manual\|0012]] | Kickoff manual com flags na primeira linha e descrição verbatim, sem shell | accepted | `app/lib/data/kickoff.dart`<br>`app/lib/features/launcher/**`<br>`skills/kickoff/SKILL.md` |  |  |
| [[0013-inventario-lido-do-disco\|0013]] | Tela Sobre gerada do inventário em disco, com parsers que nunca lançam e claudeHome único | accepted | `app/lib/data/inventory_parser.dart`<br>`app/lib/data/file_inventory_repository.dart`<br>`app/lib/core/claude_home.dart`<br>`app/lib/features/about/**`<br>`engine/data.mjs` |  |  |
| [[0014-sessao-de-org\|0014]] | Sessão de org com rótulo opaco no engine e pertença resolvida no app | accepted | `engine/engine.mjs`<br>`engine/sessions.mjs`<br>`app/lib/data/orgs.dart`<br>`app/lib/features/shell/**`<br>`app/lib/app/router.dart`<br>`app/lib/features/launcher/command_palette.dart` |  |  |
