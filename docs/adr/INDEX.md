# ADR Index

> Gerado por `adr-index.py reindex`. Não editar à mão.

| ID | Título | Status | Affects | Supersedes | Superseded by |
|---|---|---|---|---|---|
| [[0001-watcher-unico-com-classify-puro\|0001]] | Fonte reativa do app com um único watcher e classificação pura | accepted | `app/lib/data/file_flow_repository.dart`<br>`app/lib/data/workflow_parser.dart` |  |  |
| [[0002-parser-puro-separado-do-io\|0002]] | Parser puro separado do IO e modelos escritos à mão | accepted | `app/lib/data/workflow_parser.dart`<br>`app/lib/data/models.dart` |  |  |
| [[0003-stream-cubit-generico\|0003]] | Estado de UI com StreamCubit genérico e router que não lê o repositório | accepted | `app/lib/core/bloc/**`<br>`app/lib/app/**`<br>`app/lib/features/**` |  |  |
| [[0004-fixtures-geradas-pelo-persist\|0004]] | Fixtures geradas pelo persist real com checagem de drift | accepted | `app/test/fixtures/**`<br>`tests/run.sh` |  |  |
| [[0005-app-macos-sem-sandbox\|0005]] | App macOS sem App Sandbox | accepted | `app/macos/Runner/*.entitlements` |  |  |
| [[0006-testes-de-workflow-fora-do-g0\|0006]] | Testes de workflow e scripts fora do G0 | superseded | `tests/**`<br>`workflows/**`<br>`bin/**` |  | 0008 |
| [[0007-engine-node-processo-filho\|0007]] | Engine Node como processo filho com encerramento por stdin-EOF | accepted | `engine/**`<br>`app/lib/engine/**` |  |  |
| [[0008-testes-fora-do-g0-incluem-engine\|0008]] | Testes de workflow, scripts e engine fora do G0 | accepted | `tests/**`<br>`workflows/**`<br>`bin/**`<br>`engine/**` | 0006 |  |
