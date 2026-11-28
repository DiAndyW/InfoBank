# Shared behaviour

Layout and spacing belong to each app. `behaviour/behaviour.json` is the expectation for shared notices, copy actions, capture/edit interactions, error wording and theme colours on macOS, Windows and iOS. Tests read it; apps never load it at runtime.

## Change from the top down

1. Edit the rule first.
2. Run its tests on every platform and confirm they fail where behaviour must change.
3. Design each platform's change together.
4. Implement and build until all tests pass. A deliberate platform difference needs a non-empty `reason` in the rule; never invent a reason to hide drift.

If a difference needs a product decision, leave its code alone and keep that rule out of the file until the decision is made. Report the gap.

## Schema

The root has exactly `platforms` (`macos`, `windows`, `ios`) and a non-empty `rules` object. Rule IDs are `notice.name`, `copy.name`, `failure.name`, `editor.name`, `item.name`, `search.name`, `composer.name` or `style.name`, using lowercase letters, digits and underscores. Each rule has a non-empty `summary`, an `expect` object and optional `differs`.

Expectation shapes:

- `notice.duration`: `duration_seconds`, a positive number. This is the single duration rule for all notices.
- Other notices: `message` and `buttons`, with optional boolean `offered` (default true). An absent platform notice uses an `offered: false` override with a reason; inherited wording/buttons describe only the platforms that offer it. Buttons are ordered action labels (`Show`, `Undo` or `Download`) followed by `close`, the dismiss icon. Message placeholders use `{name}`; batch notices use `{count}` and `{items}` so singular and plural are tested.
- Copy places: `menu`, `row` and `batch`. Menus and batch controls are ordered arrays of `{ "id": "text", "label": "Copy Text" }`. IDs are `text`, `item` or `items`. `row` says whether activating the row copies the whole Item. `tunnel` covers a false or unanswered preference; `tunnel_trash` covers a true preference. `search` has batch actions only.
- Other copy rules: `offered` and optional `label` (for example attachment Copy). `copy.without_text` checks that attachment-only Items offer no text copy.
- Failure rules: required non-empty `message`.
- `composer.attachment_order`: exactly `expect: {"order": "input"}`; successful imports append in accepted input order, including overlapping batches and failures.
- `composer.clear`: boolean `offered` and `label`; the action is composer-wide and includes pending-only drafts. Successful persistence retires current-generation display; physical work still gates restart/editor safety. Undo excludes pending imports.
- `composer.pending_imports`: `label` for one operation, `message` with `{count}` for several, and `offered` for overlapping picker acceptance. Count accepted operations/batches, including ready results waiting for ordered publication. iOS retains the single-picker-batch API and disabled Attach while physically importing; desktop accepts overlap. Both shared trays show the current-generation count.
- Other Composer rules: required boolean `offered`; `composer.draft_attachments` asserts durable ordered attachment recovery. Desktop Quick Capture and unsent Item edits remain transient; iPhone Quick Capture uses Home.
- `item.menu`: required `actions`, a non-empty ordered array of unique IDs from `edit`, `move`, `copy_item`, `copy_text`, `trash`. Availability follows existing copy and special-path policies. `item.move_to_current` uses `offered` to say whether a move runs when its destination is already current.
- `feed.opening`: positive integer `initial_items` and `older_items` (both 30); default queries, Search and deletion batches remain 100; explicit reveal retains a continuous target-to-newest range.
- `notice.unsupported_attachment`, `notice.runnable_attachment` and `notice.filename`: unsupported attachments post a notice offering `Download`, a notice button, which asks where to save on desktop and opens the Share sheet on iPhone. The runnable notice is desktop-only; iOS uses the unsupported notice. `notice.filename` holds positive-int `max_characters` and non-empty `ellipsis` for shortening filenames in notices.
- Search rules: boolean `offered`; `search.start` offers a global start and `search.topics` offers Topics only at All places; `search.enter` protects edits before entry, and `search.activity` displays stored Topic activity locally, with `label` for one Item and `message` (`{count}`) for zero or several Items. Native Search rendering checks verify the SwiftUI count copy.
- Editor rules: at least one of `message`, `label`, `actions` or `offered`. Messages and labels are non-empty strings, `offered` is boolean, and `actions` is a non-empty ordered array of non-empty unique strings.
- `style.palette`: exactly `expect: {"match": true}`. The checker compares each iOS `Palette` colour with the desktop token for that theme, mapping camelCase to kebab-case (for example `surfaceRaised` to `--surface-raised`). Colours compare case-insensitively. Optional `rule` and `feedBar` colours are checked only when defined on iOS; desktop-only tokens are ignored. Missing desktop tokens fail. `differs.ios.expect` maps `"<theme>.<field>"` to `"#rrggbb"` for approved iOS differences, with a reason. Other style rule shapes are not yet defined.

`differs.<platform>` has exactly `expect` (a partial expectation) and a non-empty `reason`. Helpers merge its fields over the base expectation; arrays replace the base array. Unknown keys and platforms fail validation. Palette differences use the field map above rather than the base `match` field.

```json
{
  "summary": "Each attachment has its own Copy button",
  "expect": { "offered": true, "label": "Copy" },
  "differs": {
    "ios": {
      "expect": { "offered": false },
      "reason": "Quick Look's Share sheet already offers Copy"
    }
  }
}
```

## Look and feel

Controls of the same kind use the same tokens across both apps: `hover` for hover and press, accent only for primary actions and selection, danger for destructive actions and the empty-Item state, and accent for focus. Compare new controls with their siblings and the other platform.

On desktop, Enter sends or saves, Shift+Enter types a new line, and Esc cancels the editor and Quick Capture. On iPhone, Return types a new line because of the touch keyboard.

On iPhone an in-flight import can't be cancelled, so the editor's Cancel and Discard wait for it; on desktop Cancel stays enabled and the editor rejects a pending drop when it closes.

Errors name what failed as "X failed to Y." A reason the app itself wrote (its error mapping or a curated message) may follow. Never show an underlying error string or append the catch-all "Something went wrong. Try again." Underlying errors go to logs as codes; keep operation IDs and reason codes in sync logs.

## Add a rule and tests

Write the expectation before changing either app. In a desktop `src/**/*.test.ts(x)` file, register a literal `behaviourTest("area.name", async expected => { ... })` from `behaviour-test.ts`. It runs the real flow twice, stubbing `navigator.userAgent` for macOS and Windows, and supplies the merged expectation. Assert observed messages, buttons and offerings from `expected`; use `noticeMessage` to substitute fixture values. Keep app platform reads at render or action time so the stub takes effect.

In a NoteBankKit test, call `try Behaviour.rule("area.name")` with a literal ID and compare the real Kit result with that expectation. The helper finds the repo through `#filePath`. Values that used to live in SwiftUI belong in Kit, and the views must consume them. `Notice.durationSeconds` controls the notice timer; `CopyActions` supplies copy offerings and labels. Test singular/plural and preference branches where applicable.

`style.*` rules are covered by the checker itself and need no platform test registrations. `style.palette` reads `desktop/src/tokens.css` and `ios/NoteBank/Theme.swift`.

The coverage check scans desktop registrations and Swift helper calls. Each literal desktop registration covers macOS and Windows; each Swift call covers iOS. Comments do not count. Unknown references or any missing rule/platform pair fail with its name. Use direct literal calls, not dynamic IDs or aliases. This is source coverage, not proof of a meaningful assertion: run and review the tests, including a mutation of a rule value.

## Run

```sh
python3 behaviour/check.py
python3 -m unittest behaviour.test_check -v
cd desktop
npx tsc --noEmit
npx vitest run
npm run build
cd ..
swift test --package-path ios/NoteBankKit --no-parallel
xcodebuild -project ios/NoteBank.xcodeproj -scheme NoteBank -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Run Kit tests alone, before starting Xcode builds. Read the Swift Testing test count; the XCTest compatibility runner may say zero. CI's required `behaviour` job runs schema/coverage validation and the checker's unittests; desktop and Apple jobs execute the platform assertions.

Row `row` expectations also govern accessibility Copy availability. Kit tests check the policy; a source guard checks that SwiftUI conditionally registers the action. Attachment-copy notice absence is checked against the Quick Look integration source, which has no NoticeCenter or copy callback; it is not a simulated Kit notice. These source guards do not replace device accessibility or Share-sheet testing.
