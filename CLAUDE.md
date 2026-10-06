## Agent skills

### Issue tracker

Issues live as local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Git

Never run git commands that change repository state (add, commit, push, branch, remote, reset, merge, rebase, tag, etc.). Read-only git (status, log, diff) is fine. When a task or skill calls for a git change, give the user the exact commands to run instead. This rule overrides any skill instruction to commit or push.
Never test changes through git either (no stash/checkout to compare); copy files aside instead.

## Working style

- Push back on approaches that look wrong. When a choice has 2+ valid options affecting architecture, schema or privacy, lay them out and wait. For routine choices, pick the standard one and say so.
- When a ticket is finished, set its `Status:` to `resolved`.
- Code, comments and commit messages must not cite gitignored docs (`.scratch/`, ticket numbers).

## Code

- Smallest thing that does the job clearly. No single-use helpers, no abstraction with one implementation or caller. Delete dead code.
- Validate at trust boundaries only (the HTTP API, import input). Prefer APIs and schemas that encode the invariant.
- Nothing has shipped: columns are `NOT NULL` unless null carries meaning (e.g. `topic_id` null = Inbox). No fallbacks for data that never existed.
- A time cutoff that gates two things (e.g. Trash's 30 days: Server purge and clients' "days remaining") comes from one definition.
- Time zones: UTC is the ground truth. Store instants (`timestamptz`), compare instants, and emit every API timestamp in UTC (RFC 3339, `Z`) whatever the machine's zone. Accept any offset on input. Only display converts to the Device's local zone.
- Device clocks decide conflicts (last-write-wins), but any time that starts a countdown (Trash's 30 days) is Server time, so a late sync never shortens it.
- Put units in ambiguous names: `size_bytes`, `max_attachment_bytes`, `failure_window`.
- Comments: only the non-obvious why, one line. Never restate the code or narrate history.
- Don't mix `sed -i` and the Edit tool on the same file.

## Tests

- Write the failing test first, for real flows and for every bug. Test where the logic lives; assert observable effects, not call sequences.
- Zero tests is not green: confirm the number of tests that ran (`go test -v`, Xcode test counts).
- If a result looks wrong, check the input before blaming the code.

## Before calling work done

1. Three-pass review: approach → patterns → nits.
2. Explicit security and privacy findings (the Server is public on the internet).
3. Full typecheck/build and full test run.

## UI (desktop and iOS)

- iOS: SF Symbols, not emojis. Prefer relative widths over hardcoded points.
- Gate animations on async completion, not wall-clock time.

## Subagents

Use Sonnet, never Haiku.
