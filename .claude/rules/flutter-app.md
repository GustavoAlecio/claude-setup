---
paths: ["app/**"]
---

# Convenções do app Flutter (app/)

Estas regras valem para `app/` e prevalecem sobre convenções genéricas dos agentes de review (inclusive as de outros projetos embutidas na definição do agente).

- **Strings:** pt-BR hardcoded nos widgets. Não há l10n/ARB neste app — não reportar strings literais.
- **Modelos:** classes Dart imutáveis escritas à mão (`const` constructors, campos `final`, `sealed` só onde há variantes de evento). Sem freezed/json_serializable — o schema lido é externo e parcial; parse manual é decisão do plano.
- **Estado:** `flutter_bloc` só para streams de arquivo, via `StreamCubit<T>` genérico (`Cubit<AsyncSnapshot<T>>`). Widgets estáticos não ganham Cubit.
- **DI:** `RepositoryScope` (InheritedWidget) com um `FlowRepository`; escolha do repositório por `--dart-define` em `repositoryFromEnvironment()`. Sem get_it.
- **Rotas:** go_router com `ShellRoute`; rotas do shell usam `NoTransitionPage` (não animar troca de aba/drill-down).
- **Tema:** cores só via `context.colors` (`AppColors` ThemeExtension); nada de `Color(0x…)` fora de `app_colors.dart`.
- **Logs:** `dart:developer` `log()`; nunca `print`/`debugPrint`.
- **IO:** só `FileFlowRepository` toca `dart:io`; parsing em funções puras de `workflow_parser.dart`.
