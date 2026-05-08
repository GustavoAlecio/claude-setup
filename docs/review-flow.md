# Review Flow

A staged code review for PRs (or local branches).

```
┌────────┐    ┌──────────┐    ┌─────────────┐
│ review │ →  │ approve  │ →  │ post-review │
└────────┘    └──────────┘    └─────────────┘
  drafts         user gate      published to GH
```

## Stages

### `/review` — Stage 1: multi-agent review

Reads the PR diff, detects which stacks are touched (Flutter, Dart, Android, iOS, NestJS, GCP), and spawns the relevant specialized agents in parallel:

- `<stack>-architecture` — layering, module boundaries, DI
- `<stack>-correctness` — bugs, lifecycle, threading
- `<stack>-performance` — main thread, rebuilds, allocations
- `<stack>-security` — credentials, IPC, validation
- `<stack>-testing` — coverage and quality

Each agent proposes inline comments on specific lines. The review skill consolidates them into a draft and shows them to you for triage.

### `/approve-review` — Stage 2: user gate

Marks the draft as approved and ready to publish. Local-only — does NOT touch GitHub.

This is your chance to:
- Drop comments you disagree with
- Add or edit a comment
- Choose the verdict (approve / comment / request_changes)

### `/post-review` — Stage 3: publish

Posts the approved review to the GitHub PR via `gh`:
- Inline comments on specific lines
- Top-level summary
- Verdict (approve / comment / request_changes)

## `/self-review`

Same flow, but targets your **local branch** instead of an open PR. Runs the agents against the diff between your branch and `main` (or whichever base you specify). Useful before pushing — catch your own issues before reviewers do.

## Stack detection

The review skill reads the PR's changed files and matches extensions/paths against known stacks:

| Stack | Detected from |
|---|---|
| Flutter | `pubspec.yaml`, `lib/**/*.dart` |
| Dart | `*.dart` outside Flutter projects |
| Android | `*.kt`, `*.java`, `build.gradle` |
| iOS | `*.swift`, `*.m`, `*.h`, `Podfile` |
| NestJS | `*.ts` with `@nestjs/*` deps |
| GCP | `*.tf`, `cloudbuild.yaml`, `app.yaml` |

A PR that touches multiple stacks fans out to all of them in parallel.
