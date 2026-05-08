# Smart Flow

A staged workflow for non-trivial tasks. Each stage produces an artifact the next stage consumes.

```
┌─────────┐    ┌──────┐    ┌───────┐    ┌──────────┐    ┌────────┐
│ specify │ →  │ plan │ →  │ tasks │ →  │ implement │ → │ verify │
└─────────┘    └──────┘    └───────┘    └──────────┘    └────────┘
   spec         plan        tasklist     code+tests       report
```

## Stages

### `/specify` — Stage 1: business spec

Turns a fuzzy user request into a written business specification with:
- Goal
- Acceptance criteria
- Out-of-scope items
- Open questions

User reviews and approves before moving on.

### `/plan` — Stage 2: technical plan

Reads the approved spec and produces a technical implementation plan:
- Affected files / modules
- Architectural choices
- Risks and trade-offs
- Test strategy

User reviews and approves.

### `/tasks` — Stage 3: ordered task list

Splits the approved plan into ordered, atomic tasks. Each task is:
- Self-contained
- Independently verifiable
- Small enough to land in one commit

### `/implement` — Stage 4: execution

Executes the tasks in order, following the plan. Updates each task's status as it completes.

### `/verify` — Stage 5: validation

Runs the implementation against the spec's acceptance criteria. Reports pass/fail per criterion.

## Helpers

- `/auto` — toggle autopilot. With autopilot on, stages advance without manual approval gates.
- `/status` — show the current stage, what's done, and what's next.
- `/fix` — lighter flow for bugs. Investigate → diagnose → fix → verify, without the full pipeline.

## When to use the full flow vs `/fix`

Use the **full Smart Flow** when:
- The change spans multiple files or modules
- There are non-trivial design decisions
- You want a written record of intent (spec) and approach (plan)

Use **`/fix`** when:
- It's clearly a single-cause bug
- The fix is small and the change is obvious once root cause is found
- The full pipeline would be ceremony

## Outputs

Each cycle's artifacts (spec, plan, tasks, implementation log, verification) are stored in `~/.claude/workflow/<project>/` so you can revisit, copy, or attach them to a PR description.
