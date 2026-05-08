---
name: dart-clean-arch
description: Opinionated Dart conventions for medium/large Flutter apps — sealed freezed classes, Entity/Model/Response/Request naming, extensions with Extension suffix, exhaustive pattern matching, strict very_good_analysis. Use when writing entities, models, exceptions, enums or extensions in projects that adopt Clean Architecture.
---

# Dart — Clean Architecture conventions

Opinionated Dart conventions for Flutter projects that follow Clean Architecture with `data/domain/presentation` layers. Pair with the `flutter-clean-arch` skill for the framework side.

> These conventions are **opinionated** and reflect patterns used in production apps. They are not doctrine — adopt, adapt, or ignore based on your project context.

## Assumed stack

- Dart 3.0+ (sealed classes, switch expression, records, pattern matching).
- `freezed` + `json_serializable` for data classes.
- `very_good_analysis` (or equivalent strict ruleset) with `dart analyze --fatal-infos --fatal-warnings` in CI.
- `build_runner` for code generation.

## Naming

| Type | Class suffix | File |
|---|---|---|
| Entity (domain) | **none** — `Task` | `task.dart` |
| Model (data DTO) | `Model` — `TaskModel` | `task_model.dart` |
| Response (API) | `Response` — `TaskResponse` | `task_response.dart` |
| Request (payload) | `Request` — `CreateTaskRequest` | `create_task_request.dart` |
| Interface | `I` prefix — `ITasksRepository` | `tasks_repository.dart` |
| Implementation | no prefix — `TasksRepository` | `tasks_repository.dart` |
| Bloc | `Bloc` — `TasksBloc` | `tasks_bloc.dart` |
| Cubit | `Cubit` — `TasksCubit` | `tasks_cubit.dart` |
| UseCase | `UseCase` — `FetchTasksUseCase` | `fetch_tasks_usecase.dart` |
| Page | `Page` — `TaskDetailPage` | `task_detail_page.dart` |
| Extension | `Extension` — `MoneyExtension` | `money_extension.dart` |
| Status enum | `Status` — `TasksStatus` (legacy) | `tasks_status.dart` |
| Domain enum | `Enum` when ambiguous — `PriorityEnum` | — |

**Critical rules:**
- Entity has **no** suffix. `Task`, not `TaskEntity`.
- Model **always** has `Model` suffix.
- Extension uses `Extension` suffix, **not `X`** (even though `X` is common in the Dart ecosystem).
- Interface uses `I` prefix (Effective Dart discourages this — opinionated convention here).

## Freezed always

Every data class uses freezed sealed/abstract.

```dart
// Entity (domain) — sealed, no suffix, no fromJson
@Freezed(map: FreezedMapOptions.none, when: FreezedWhenOptions.none)
sealed class Task with _$Task {
  const factory Task({
    required String id,
    required String title,
    required bool completed,
  }) = _Task;
}

// Model (data) — abstract, with fromJson + conversion bridge
@Freezed(map: FreezedMapOptions.none, when: FreezedWhenOptions.none)
abstract class TaskModel with _$TaskModel {
  factory TaskModel({
    required String id,
    required String title,
    required bool completed,
  }) = _TaskModel;

  factory TaskModel.fromJson(Map<String, dynamic> json) =>
      _$TaskModelFromJson(json);

  factory TaskModel.fromEntity(Task entity) => TaskModel(
        id: entity.id,
        title: entity.title,
        completed: entity.completed,
      );

  Task toEntity() => Task(id: id, title: title, completed: completed);
}
```

**Rules:**
- Default annotation: `@Freezed(map: FreezedMapOptions.none, when: FreezedWhenOptions.none)`. Use the short `@freezed` only when intentional — disabling `map`/`when` forces you to use pattern matching, which is the goal.
- Entity is `sealed class`. Model is `abstract class`.
- **Entity never has `fromJson`/`toJson`** — domain doesn't know about serialization.
- Model is the bridge: `fromJson` (API → Model), `toEntity()` (Model → Entity), `fromEntity()` (Entity → Model).
- Defaults via named factory (`Task.empty()`), not via default parameters.

## Sealed unions for sum types

Every sum type (result, error, state) uses sealed freezed with named factories.

```dart
@Freezed(map: FreezedMapOptions.none, when: FreezedWhenOptions.none)
sealed class ApiResult<T> with _$ApiResult<T> {
  const factory ApiResult.success({required T data}) = _Success<T>;
  const factory ApiResult.failure({
    required Exception exception,
    required StackTrace stackTrace,
  }) = _Failure<T>;
}
```

Consumed with pattern matching (preferred in Dart 3+):

```dart
return switch (result) {
  _Success(:final data) => data.toEntity(),
  _Failure(:final exception, :final stackTrace) =>
      _exceptionHandler.handle(exception, stackTrace),
};
```

## Exceptions: sealed `AppException`

Every custom app exception derives from a single sealed tree. Mapping status code → exception is the responsibility of a central `ExceptionHandler`. Repos do NOT know about status codes.

```dart
@Freezed(map: FreezedMapOptions.none, when: FreezedWhenOptions.none)
sealed class AppException implements Exception with _$AppException {
  factory AppException.network() = NetworkException;
  factory AppException.validation({required String message}) = ValidationException;
  factory AppException.unauthorized() = UnauthorizedException;
  factory AppException.unknown() = UnknownException;
}
```

## Extensions

Location: `lib/core/extensions/<topic>_extension.dart` or in the package where it makes sense.

```dart
extension MoneyExtension on int {
  String toUSD() => '\$${(this / 100).toStringAsFixed(2)}';
}

extension TaskExtension on Task {
  bool get isOverdue =>
      dueDate != null && dueDate!.isBefore(DateTime.now()) && !completed;
}
```

**Rules:**
- `Extension` suffix (not `X`).
- Use extension for computed properties on freezed entities/states (which are immutable).
- One file per extended type. Don't group extensions of different types in the same file.

## Pattern matching

Use `switch` expression whenever possible on sealed types. No `default:` when all cases are covered — `exhaustive_cases` enforces this.

```dart
final color = switch (priority) {
  Priority.high => Colors.red,
  Priority.medium => Colors.orange,
  Priority.low => Colors.green,
};

final widget = switch (state) {
  TasksInitial() || TasksLoading() => const LoadingIndicator(),
  TasksLoaded(:final tasks) => TasksList(tasks: tasks),
  TasksError(:final message) => ErrorView(message: message),
};
```

Avoid chained if/else on sealed types.

## Async

- `Future<T>` for I/O operations. Never `Future<void>` when there's a result to propagate.
- Explicit `unawaited(...)` for fire-and-forget (lint enforces `unawaited_futures`).
- `runZonedGuarded` in `main()` for top-level error capture.
- Broadcast streams (`StreamController.broadcast()`) for cross-feature signals (session expired, maintenance, connectivity).
- No `async*` — prefer explicit `StreamController`.

## Imports

- `prefer_relative_imports: true` within the same package.
- `package:` only cross-package.
- Explicit barrel files: `domain.dart`, `data.dart`, `presentation.dart`, `feature.dart`.

## Strict lint

```yaml
include: package:very_good_analysis/analysis_options.5.1.0.yaml

analyzer:
  strict-casts: true
  strict-inference: true
  strict-raw-types: true
  exclude: ["**/*.g.dart", "**/*.freezed.dart", "**/*.gen.dart"]

linter:
  rules:
    - exhaustive_cases
    - unawaited_futures
    - cancel_subscriptions
    - close_sinks
    - avoid_print
    - use_super_parameters
```

`avoid_print` blocks `print()` — use a dedicated logger.

## Code generation

```bash
dart run build_runner build --delete-conflicting-outputs
# or if using melos
melos run gen
```

**Never** edit manually: `*.freezed.dart`, `*.g.dart`, `*.gen.dart`, `app_localizations_*.dart`.

## Records

Use **sparingly** — only for local tuples without strong semantics. For anything with more than 2 fields OR domain meaning → freezed sealed class.

```dart
final (int, int) range = (3, 7);  // OK for local use

// DON'T use records to represent domain:
// final ({String id, String title, bool done}) task;  // ❌ — make it a Task
```

## Const and immutability

- Every freezed entity/state should be `const` when possible.
- Lists in states: `@Default(<Task>[])` (not raw `[]` — preserves type).
- Prefer `const` constructors and literals in widgets.

## Dart checklist

- [ ] Entity without suffix? Model with `Model`? Response with `Response`? Request with `Request`?
- [ ] Annotation `@Freezed(map: FreezedMapOptions.none, when: FreezedWhenOptions.none)`?
- [ ] Entity is `sealed class`? Model is `abstract class`?
- [ ] Entity without `fromJson`/`toJson`?
- [ ] Model implements `fromJson`, `fromEntity`, `toEntity`?
- [ ] Extension with `Extension` suffix (not `X`)?
- [ ] Exhaustive `switch` on sealed (no unnecessary `default`)?
- [ ] Build runner run after changing freezed/json?
- [ ] `dart analyze --fatal-infos --fatal-warnings` passes?
