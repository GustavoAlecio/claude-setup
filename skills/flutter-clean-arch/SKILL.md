---
name: flutter-clean-arch
description: Opinionated Flutter architecture — Clean Architecture (data/domain/presentation), Cubit-first with Bloc only for global state, multi-state pattern (factory per state, no status enum), go_router with centralized Routes, manual DI via providers, repository with I interface + mandatory UseCase, mocktail + bloc_test. Use when creating features, blocs/cubits, routes, repositories or widgets in projects with these conventions.
---

# Flutter — Clean Architecture conventions

Opinionated Flutter architecture conventions for medium/large apps. Pair with `dart-clean-arch` for the language side.

> Opinionated and adapted from production projects. Adopt, adapt, or ignore based on context.

## Clean Architecture

```
Presentation → Domain ← Data
```

- **Presentation** depends on Domain (entities, usecases).
- **Data** depends on Domain (implements contracts).
- **Domain** depends on nothing external (no Flutter, no Dio, no I/O libs).

Each feature/package has three layers: `data/`, `domain/`, `presentation/`.

```
lib/src/
├── data/
│   ├── apis/              # HTTP call wrappers
│   ├── datasources/       # Interfaces + implementations
│   ├── models/
│   │   ├── request/
│   │   └── response/
│   ├── repositories/      # Contract implementations
│   ├── errors/
│   │   ├── exceptions/
│   │   └── failures/
│   └── services/
├── domain/
│   ├── entities/          # Domain sealed classes
│   ├── repositories/      # Interfaces (with I prefix)
│   ├── usecases/          # One per operation
│   └── value_objects/
└── presentation/
    ├── bloc/              # Events + states + bloc class
    ├── cubits/            # State + cubit class
    ├── pages/             # Routed screens
    ├── views/             # Sub-screens / tabs
    └── widgets/           # Reusable components
```

## State management: Cubit-first

Lib: `flutter_bloc`. **Main rule**: Cubit for almost everything, Bloc only for global/cross-cutting state.

### Cubit (default for local features)

- **1:1 rule**: one Cubit per feature/operation.
- Created via `BlocProvider` at the page/feature level.
- No events — public methods on the cubit.

```dart
class TasksCubit extends Cubit<TasksState> {
  TasksCubit(this._useCase) : super(const TasksState.initial());

  final IFetchTasksUseCase _useCase;

  Future<void> fetchTasks() async {
    emit(const TasksState.loading());
    try {
      final tasks = await _useCase.execute();
      emit(TasksState.loaded(tasks: tasks));
    } on AppException catch (e) {
      emit(TasksState.error(message: e.toString()));
    }
  }
}
```

### Bloc (global state only)

Use Bloc only for **app-wide cross-cutting** features:
- Authentication, language, theme, connectivity, shared websocket, environment.

They live in `lib/core/shared/` and are provided at the root level. They use events because they react to multiple sources (streams, lifecycle, other blocs).

> Legacy code often uses Bloc for everything. When touching a local feature still using Bloc, migrate to Cubit.

## Multi-state pattern (MANDATORY)

**No status enum with a single state class.** Each state is a separate factory in the sealed class.

```dart
@Freezed(map: FreezedMapOptions.none, when: FreezedWhenOptions.none)
sealed class TasksState with _$TasksState {
  const factory TasksState.initial() = TasksInitial;
  const factory TasksState.loading() = TasksLoading;
  const factory TasksState.loaded({required List<Task> tasks}) = TasksLoaded;
  const factory TasksState.error({String? message}) = TasksError;
}
```

**Why**: each state carries only the data that makes sense in it. `tasks` only exists in `TasksLoaded` — no useless null check in `TasksLoading`.

**UI consumption** with pattern matching:

```dart
BlocBuilder<TasksCubit, TasksState>(
  builder: (context, state) => switch (state) {
    TasksInitial() || TasksLoading() => const LoadingIndicator(),
    TasksLoaded(:final tasks) => TasksList(tasks: tasks),
    TasksError(:final message) => ErrorView(message: message),
  },
)
```

**Rules:**
- **Never** `emit(state.copyWith(...))` to switch states — emit the correct state directly.
- `copyWith` only within the same factory (e.g., updating a field inside `TasksLoaded`).
- No `enum TasksStatus { initial, loading, loaded, error }` in a single field.

## Layers: data → domain ← presentation

```
Page/Widget
   ↓
Cubit/Bloc        ← calls UseCase
   ↓
UseCase           ← orchestrates Repository
   ↓
IRepository (domain) — implemented by Repository (data)
   ↓
Datasource (data) — calls Api
   ↓
Api               ← returns ApiResult<Model>
```

### Repository pattern

Domain defines interface with `I` prefix, data implements.

```dart
// domain/repositories/tasks_repository.dart
abstract class ITasksRepository {
  Future<List<Task>> fetchTasks();
}

// data/repositories/tasks_repository.dart
class TasksRepository implements ITasksRepository {
  TasksRepository(this._tasksApi, this._exceptionHandler);

  final TasksApi _tasksApi;
  final IExceptionHandler _exceptionHandler;

  @override
  Future<List<Task>> fetchTasks() async {
    final result = await _tasksApi.fetchTasks();
    return switch (result) {
      _Success(:final data) => data.map((m) => m.toEntity()).toList(),
      _Failure(:final exception, :final stackTrace) =>
          throw _exceptionHandler.handle(exception, stackTrace),
    };
  }
}
```

### Mandatory UseCase

**Cubit/Bloc never calls Repository directly.** Always via UseCase, even if it's pass-through.

```dart
abstract class IFetchTasksUseCase {
  Future<List<Task>> execute();
}

class FetchTasksUseCase implements IFetchTasksUseCase {
  FetchTasksUseCase(this._repository);
  final ITasksRepository _repository;

  @override
  Future<List<Task>> execute() => _repository.fetchTasks();
}
```

**Why**: makes business logic easier to test in isolation, allows composing multiple repos, and adds an extension point without touching repo or cubit.

## Dependency Injection: manual

**No GetIt, no global Riverpod, no service locator.** Everything is instantiated manually and injected via constructor.

Each package/feature exposes `<name>_providers.dart`:

```dart
class TasksProviders {
  TasksProviders._();

  static Future<List<RepositoryProvider<dynamic>>> resolve() async {
    return [
      RepositoryProvider<ITasksRepository>(
        create: (ctx) => TasksRepository(
          ctx.read<TasksApi>(),
          ctx.read<IExceptionHandler>(),
        ),
      ),
      RepositoryProvider<IFetchTasksUseCase>(
        create: (ctx) => FetchTasksUseCase(ctx.read<ITasksRepository>()),
      ),
    ];
  }
}
```

`main.dart` aggregates all of them via `Future.wait`. Root app mounts `MultiRepositoryProvider`.

```dart
final repositories = (await Future.wait([
  AuthProviders.resolve(),
  TasksProviders.resolve(),
  // ...
])).expand((e) => e).toList();

runApp(MyApp(repositories: repositories));
```

**Access in widget**: `context.read<IFetchTasksUseCase>()`.

**Cubit/Bloc**: created per-page via `BlocProvider(create: (ctx) => TasksCubit(ctx.read<IFetchTasksUseCase>()))`.

## Routing: go_router + centralized `Routes`

Lib: `go_router`. Single definition in `lib/core/router/app_router.dart`.

**Route names centralized** in a `Routes` class:

```dart
// lib/core/router/routes.dart
class Routes {
  const Routes._();
  static const home = 'home';
  static const tasksList = 'tasks-list';
  static const taskDetail = 'task-detail';
}
```

**On the page**: `route` is **derived from `name`**, and `name` references `Routes`.

```dart
class TasksListPage extends StatefulWidget {
  static const name = Routes.tasksList;     // references Routes
  static const route = '/$name';            // derived from name
}
```

**Never hardcode** route strings on the page. Every new route: add to `Routes` first.

**Complex parameters**: JSON-stringified in `state.extra`.

```dart
context.push(TaskDetailPage.route, extra: jsonEncode(params.toJson()));

// builder:
final data = jsonDecode(state.extra! as String) as Map<String, dynamic>;
return TaskDetailPage(params: TaskParams.fromJson(data));
```

**Redirect**: pure function `computeRedirect()` (testable in isolation).

## Error handling

```
API → Repository → ExceptionHandler → throw AppException
```

- 401 → `sessionExpired` stream → automatic logout.
- 503 → `maintenance` stream → UI shows maintenance screen.
- Others → Cubit/Bloc catches and emits `state.error()`.

```dart
try {
  final data = await _useCase.execute();
  emit(State.loaded(data: data));
} on AppException catch (e) {
  emit(State.error(message: e.toString()));
}
```

## Local cache

| Lib | When |
|---|---|
| `hive` or `isar` | Structured with schema |
| `shared_preferences` | Simple key-value (last email, onboarding flags) |

Pick **one** structured lib per project and stay consistent.

## Localization

- `intl` + ARB files.
- In monorepos: each package has its own `lib/l10n/` and exposes a `LocalizationsDelegate`.
- Root app lists all delegates in `localizationsDelegates`.

## Widgets

- **Stateless predominantly** with external Cubit/Bloc via `BlocBuilder`/`BlocListener`.
- **No `flutter_hooks`** (optional — discardable opinion).
- Shared widgets in `lib/core/shared/presentation/widgets/`.
- Assets via `flutter_gen`: `Assets.images.logo`.
- Theme via `BuildContext` extension: `context.colorPalette`, `context.spacing`.

## Tests

Stack: `flutter_test` + `bloc_test` + `mocktail`. **Never mockito.**

Structure mirrors `lib/`. Widget test helper in `test/helpers/pump_app.dart`.

```dart
class MockFetchTasksUseCase extends Mock implements IFetchTasksUseCase {}

void main() {
  late MockFetchTasksUseCase mockUseCase;
  late TasksCubit cubit;

  setUp(() {
    mockUseCase = MockFetchTasksUseCase();
    cubit = TasksCubit(mockUseCase);
  });

  group('TasksCubit', () {
    blocTest<TasksCubit, TasksState>(
      'emits [loading, loaded] when fetchTasks succeeds',
      build: () {
        when(() => mockUseCase.execute()).thenAnswer((_) async => mockTasks);
        return cubit;
      },
      act: (c) => c.fetchTasks(),
      expect: () => [
        const TasksState.loading(),
        TasksState.loaded(tasks: mockTasks),
      ],
    );

    blocTest<TasksCubit, TasksState>(
      'emits [loading, error] when fetchTasks fails',
      build: () {
        when(() => mockUseCase.execute()).thenThrow(AppException.network());
        return cubit;
      },
      act: (c) => c.fetchTasks(),
      expect: () => [
        const TasksState.loading(),
        isA<TasksError>(),
      ],
    );
  });
}
```

`registerFallbackValue` for custom types in `any()` matchers. Mocks: `class MockX extends Mock implements IX {}`.

## New package checklist

1. Path dependency in root `pubspec.yaml`.
2. `<pkg>_providers.dart` with `static Future<List<RepositoryProvider>> resolve()`.
3. `resolve()` added to `main.dart` `Future.wait`.
4. `<pkg>_router.dart` with `static List<RouteBase> get routes` (if the feature has routes).
5. ARB files in `lib/l10n/` of the package + delegate registered in root app.
6. `flutter_gen` config in package's `pubspec.yaml` (if it uses assets).

## Suggested tooling

```bash
# Full setup
flutter pub get && dart run build_runner build --delete-conflicting-outputs

# Format + analyze (pre-commit)
dart format . && dart analyze --fatal-infos --fatal-warnings

# Tests
flutter test
flutter test --coverage

# l10n generation
flutter gen-l10n
```

In monorepos, consider `melos` or a `Makefile` that scopes commands per package.

## `_v2` convention for gradual refactors

Features being refactored get the `_v2` suffix. When touching:

1. Check if the old version is still referenced.
2. Don't mix logic between versions — duplicate if needed.
3. New code always in `_v2`.

After full migration, delete the old one and remove the suffix.

## Feature creation checklist

- [ ] Folder with `data/`, `domain/`, `presentation/` layers?
- [ ] Cubit (not Bloc) if it's a local feature?
- [ ] Multi-state with factory per state (no status enum)?
- [ ] Repository with `I` interface in domain, impl in data?
- [ ] UseCase between Cubit and Repository (even if pass-through)?
- [ ] Model with `fromJson` + `fromEntity` + `toEntity`?
- [ ] Route added to `Routes` and `name`/`route` derived on the page?
- [ ] Provider exposed via `<pkg>_providers.dart` (if cross-feature)?
- [ ] ARBs in supported languages + `flutter gen-l10n`?
- [ ] Cubit test with `bloc_test` + `mocktail`?
- [ ] Pattern matching with `switch` in `BlocBuilder`?
- [ ] Build runner run, analyze passes, tests pass?
