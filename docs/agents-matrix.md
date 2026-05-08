# Agents Matrix

The 30 review agents are organized as a 6 × 5 matrix: **stack × concern**.

|  | Architecture | Correctness | Performance | Security | Testing |
|---|---|---|---|---|---|
| **Flutter** | layering, BLoC boundaries, DI, routing | lifecycle, async, widget bugs | rebuilds, list rendering, frame budget | storage, deep links, secrets | bloc_test, widget tests, mocktail |
| **Dart** | sealed types, freezed, package layering | null safety, async, types, errors | allocations, async patterns, collections | input parsing, regex, deserialization | coverage and quality at language level |
| **Android (Kotlin)** | MVVM, repository, DI, modularization | lifecycle, threading, leaks | main thread, layouts, memory | components, storage, IPC, permissions | unit, instrumentation, espresso |
| **iOS (Swift)** | MVVM/MVC, DI, modules | optionals, retain cycles, threading | main thread, layouts, cell reuse | Keychain, ATS, deep links | XCTest, async, snapshot, UI |
| **NestJS** | module/service boundaries, DI, layering | DI, async errors, DTOs, transactions | N+1, caching, blocking, scaling | authn/z, validation, injection, CORS | unit, e2e, providers mocking |
| **GCP** | modules, env separation, project organization | Terraform/cloudbuild correctness | scaling, regions, cold starts | IAM, secrets, network, public exposure | plan, validate, dry-runs |

## How agents are picked

The `review` skill reads the diff and picks the rows that apply (Flutter, Dart, etc.) and runs all 5 columns for each. Concerns that have nothing to flag return quickly with no comments.

## When to spawn agents directly

Outside the review flow, you can call any agent on its own — useful for:

- **One-off audits**: "Run `flutter-performance` on `lib/features/feed/`"
- **Pre-commit sanity check**: "Run `dart-correctness` on the files I just edited"
- **Cross-cutting investigation**: "Run all 5 `flutter-*` agents on this single feature"

Each agent file is self-contained — open it to see exactly what it looks for.

## Adding a new agent

To add `<stack>-<concern>`:

1. Drop the markdown file in `agents/<stack>-<concern>.md` following the format of an existing one.
2. Add it to the relevant `bundles/agents-<stack>.txt`.
3. Update this matrix.
4. Re-run `./install.sh` (or rely on the existing symlink — Claude Code will pick it up).

The agent's frontmatter `description` is what `review` reads to decide if/when to spawn it.
