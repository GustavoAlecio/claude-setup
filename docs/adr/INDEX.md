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
