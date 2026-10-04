## Agent skills

### Issue tracker

Issues live as local markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Git

Never run git commands that change repository state (add, commit, push, branch, remote, reset, merge, rebase, tag, etc.). Read-only git (status, log, diff) is fine. When a task or skill calls for a git change, give the user the exact commands to run instead. This rule overrides any skill instruction to commit or push.
