# Shared behaviour

`behaviour/behaviour.json` is the expectation for shared notices and copy actions on macOS, Windows and iOS. Tests read it; apps never load it at runtime. Layout, gestures and spacing belong to each app.

## Change from the top down

1. Edit the rule first.
2. Run its tests on every platform and confirm they fail where behaviour must change.
3. Design each platform's change together.
4. Implement and build until all tests pass. A deliberate platform difference needs a non-empty `reason` in the rule; never invent a reason to hide drift.

If a difference needs a product decision, leave its code alone and keep that rule out of the file until the decision is made. Report the gap.

## Schema

The root has exactly `platforms` (`macos`, `windows`, `ios`) and a non-empty `rules` object. Rule IDs are `notice.name` or `copy.name`, using lowercase letters, digits and underscores. Each rule has a non-empty `summary`, an `expect` object and optional `differs`.

Expectation shapes:

- `notice.duration`: `duration_seconds`, a positive number. This is the single duration rule for all notices.
- Other notices: `message` and `buttons`, with optional boolean `offered` (default true). An absent platform notice uses an `offered: false` override with a reason; inherited wording/buttons describe only the platforms that offer it. Buttons are ordered action labels (`Show` or `Undo`) followed by `close`, the dismiss icon. Message placeholders use `{name}`; batch notices use `{count}` and `{items}` so singular and plural are tested.
- Copy places: `menu`, `row` and `batch`. Menus and batch controls are ordered arrays of `{ "id": "text", "label": "Copy Text" }`. IDs are `text`, `item` or `items`. `row` says whether activating the row copies the whole Item. `tunnel` covers a false or unanswered preference; `tunnel_trash` covers a true preference. `search` has batch actions only. Archived Topics have their own rule.
- Other copy rules: `offered` and optional `label` (for example attachment Copy). `copy.without_text` checks that attachment-only Items offer no text copy.

`differs.<platform>` has exactly `expect` (a partial expectation) and a non-empty `reason`. Helpers merge its fields over the base expectation; arrays replace the base array. Unknown keys and platforms fail validation.

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

## Add a rule and tests

Write the expectation before changing either app. In a desktop `src/**/*.test.ts(x)` file, register a literal `behaviourTest("area.name", async expected => { ... })` from `behaviour-test.ts`. It runs the real flow twice, stubbing `navigator.userAgent` for macOS and Windows, and supplies the merged expectation. Assert observed messages, buttons and offerings from `expected`; use `noticeMessage` to substitute fixture values. Keep app platform reads at render or action time so the stub takes effect.

In a NoteBankKit test, call `try Behaviour.rule("area.name")` with a literal ID and compare the real Kit result with that expectation. The helper finds the repo through `#filePath`. Values that used to live in SwiftUI belong in Kit, and the views must consume them. `Notice.durationSeconds` controls the notice timer; `CopyActions` supplies copy offerings and labels. Test singular/plural and preference branches where applicable.

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
