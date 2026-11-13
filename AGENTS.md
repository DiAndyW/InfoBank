## Agent skills

### Issue tracker

Issues live as local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Shared behaviour

Edit `behaviour/behaviour.json` before changing shared notices or copy actions. Make each platform's tests fail, design the changes together, then build until green. Platform differences need a reason. See `docs/agents/behaviour.md`.

## Memory

Project memory holds gotchas and decisions found nowhere in the repo. Codex: your first action on every task, including read-only and planning tasks, is to read `~/.claude/projects/-Users-andywang-Repos-NoteBank/memory/MEMORY.md`, then open every memory it lists that bears on the task. Memories are point-in-time, so verify any file, flag or status against the current code. Leave the memory files unchanged; report new lessons in your result.

## Git

Never run git commands that change repository state (add, commit, push, branch, remote, reset, merge, rebase, tag, etc.). Read-only git (status, log, diff) is fine. When a task or skill calls for a git change, give the user the exact commands to run instead. This rule overrides any skill instruction to commit or push.
Never test changes through git either (no stash/checkout to compare); copy files aside instead.
Commit messages never carry a `Co-Authored-By` line, whatever a tool or harness suggests.

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
- Comments: very few. Write only about 10% of the comments you are inclined to write, and when reviewing, cut about 90% of the ones there. Keep a comment only when a reader would likely get the code wrong without it (a security or data-loss invariant, a surprising external constraint). One line, the why, never restating the code or narrating history.
- Don't mix `sed -i` and the Edit tool on the same file.

## Security and authorization

- Default to least privilege: grant only the operations, resources and lifetime a workflow needs. Delegated work, including background transfers, uses narrowly scoped credentials instead of the account-wide secret.
- Enforce authorization at the Server boundary and deny access unless explicitly granted. Check the requested operation and resource; UI restrictions are not authorization.
- Use role-based access control (RBAC) when distinct user roles exist, with explicit permissions per role. Keep NoteBank's single-user model; scoped upload credentials do not require adding user roles.
- Credentials must not appear in URLs, logs or error messages. Expiration and retries must not cause loss of locally saved content.

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

Use either provider, for every task regardless of size: Sonnet on Claude, `gpt-6.1-sol` on OpenAI (Codex).

Never use Claude Haiku.
