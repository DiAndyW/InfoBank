import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = {"platforms": ["macos", "windows", "ios"], "rules": {
            "notice.copied_text": {"summary": "Copy confirms", "expect": {"message": "Copied text", "buttons": ["close"]}}
        }}
        self.css = ':root, :root[data-theme="paper"] { --hover: #e5ddcc; --surface-raised: #fffcf6; --feed-bar: #f6f1e700; }'
        self.swift = 'enum Theme: String, CaseIterable {\ncase paper\nvar palette: Palette { switch self {\ncase .paper: Palette(hover: Color(0xe5ddcc), surfaceRaised: Color(0xfffcf6))\n} } }'
        self.desktop = 'behaviourTest("notice.copied_text", expected => expect(message).toBe(expected.message));'
        self.ios = 'let expected = try Behaviour.rule("notice.copied_text")'

    def run_check(self):
        (self.root / "behaviour").mkdir(exist_ok=True)
        (self.root / "behaviour/behaviour.json").write_text(json.dumps(self.file))
        (self.root / "desktop/src").mkdir(parents=True, exist_ok=True)
        (self.root / "desktop/src/Flow.test.tsx").write_text(self.desktop)
        (self.root / "ios/NoteBankKit/Tests").mkdir(parents=True, exist_ok=True)
        (self.root / "ios/NoteBankKit/Tests/FlowTests.swift").write_text(self.ios)
        (self.root / "desktop/src/tokens.css").write_text(self.css)
        (self.root / "ios/NoteBank").mkdir(parents=True, exist_ok=True)
        (self.root / "ios/NoteBank/Theme.swift").write_text(self.swift)
        return subprocess.run([sys.executable, str(Path(__file__).with_name("check.py")), "--root", str(self.root)], capture_output=True, text=True)

    def test_feed_page_sizes_are_positive_integers(self):
        self.file["rules"]["feed.opening"] = {"summary": "Bounded opening", "expect": {"initial_items": 30, "older_items": 30}}
        self.desktop += '\nbehaviourTest("feed.opening", expected => {});'
        self.ios += '\ntry Behaviour.rule("feed.opening")'
        self.assertEqual(self.run_check().returncode, 0)
        for field in ["initial_items", "older_items"]:
            for value in [0, -1, True, 1.5, "30", None]:
                self.file["rules"]["feed.opening"]["expect"] = {"initial_items": 30, "older_items": 30, field: value}
                self.assertNotEqual(self.run_check().returncode, 0)

    def test_item_actions_are_strict_and_ordered(self):
        self.file["rules"]["item.menu"] = {"summary": "Commands", "expect": {"actions": ["edit", "move", "copy_item", "copy_text", "trash"]}}
        self.desktop += '\nbehaviourTest("item.menu", expected => {});'
        self.ios += '\ntry Behaviour.rule("item.menu")'
        self.assertEqual(self.run_check().returncode, 0)
        for actions in [[], ["edit", "edit"], ["unknown"], [1]]:
            self.file["rules"]["item.menu"]["expect"]["actions"] = actions
            self.assertNotEqual(self.run_check().returncode, 0)

    def test_composer_boolean_family(self):
        self.file["rules"]["composer.x"] = {"summary": "Draft", "expect": {"offered": True}}
        self.desktop += '\nbehaviourTest("composer.x", expected => {});'
        self.ios += '\ntry Behaviour.rule("composer.x")'
        self.assertEqual(self.run_check().returncode, 0)
        for value in [1, "true", None]:
            self.file["rules"]["composer.x"]["expect"]["offered"] = value
            self.assertNotEqual(self.run_check().returncode, 0)

    def test_attachment_order_is_strict(self):
        self.file["rules"]["composer.attachment_order"] = {"summary": "Order", "expect": {"order": "input"}}
        self.desktop += '\nbehaviourTest("composer.attachment_order", expected => {});'
        self.ios += '\ntry Behaviour.rule("composer.attachment_order")'
        self.assertEqual(self.run_check().returncode, 0)
        for value in ["completion", "", True, None, []]:
            self.file["rules"]["composer.attachment_order"]["expect"] = {"order": value}
            self.assertNotEqual(self.run_check().returncode, 0)

    def test_failure_rule_needs_message(self):
        self.file["rules"]["failure.x"] = {"summary": "Failure", "expect": {"label": "x"}}
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required ['message']", result.stdout)

    def test_editor_actions_must_be_strings(self):
        for actions in [[], [""], ["  "], [1], ["Save", "Save"]]:
            with self.subTest(actions=actions):
                self.file["rules"]["editor.x"] = {"summary": "Editor", "expect": {"actions": actions}}
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid actions", result.stdout)

    def add_palette_rule(self):
        self.file["rules"]["style.palette"] = {"summary": "Colours match", "expect": {"match": True}}

    def test_palette_match_passes(self):
        self.add_palette_rule()
        self.css = self.css.replace("#e5ddcc", "#E5DDCC").replace("#fffcf6", "#FFFCF6")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("style.palette ios: covered", result.stdout)

    def test_palette_mismatch_names_theme_and_token(self):
        self.add_palette_rule()
        self.swift = self.swift.replace('0xe5ddcc', '0x123456')
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("paper.hover: desktop #e5ddcc ios #123456", result.stdout)

    def test_palette_whitespace_before_colon_still_compares_paper(self):
        self.add_palette_rule()
        self.css += '\n:root[data-theme="blackboard"] { --hover: #27302b; }\n:root[data-theme="notepad"] { --hover: #ebdc95; }'
        self.swift = self.swift.replace('case paper', 'case paper, blackboard, notepad').replace(
            'case .paper:', 'case .blackboard: Palette(hover: Color(0x27302b))\ncase .notepad: Palette(hover: Color(0xebdc95))\ncase .paper :')
        self.swift = self.swift.replace('0xe5ddcc', '0x123456')
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("paper.hover: desktop #e5ddcc ios #123456", result.stdout)
        self.swift = self.swift.replace('0x123456', '0xe5ddcc')
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_palette_theme_completeness_names_missing_or_unparsed_theme(self):
        self.add_palette_rule()
        css, swift = self.css, self.swift
        for source in ["enum only", "desktop only", "missing desktop", "unparsed desktop", "unparsed ios"]:
            with self.subTest(source=source):
                self.css, self.swift = css, swift
                if source != "desktop only":
                    self.swift = self.swift.replace('case paper\n', 'case paper, notepad\n')
                if source in {"desktop only", "unparsed ios"}:
                    self.css += '\n:root[data-theme="notepad"] { --hover: #ebdc95; }'
                if source in {"missing desktop", "unparsed desktop"}:
                    self.swift = self.swift.replace('case .paper:', 'case .notepad: Palette(hover: Color(0xebdc95))\ncase .paper:')
                    self.file["rules"]["style.palette"]["differs"] = {"ios": {"expect": {"notepad.hover": "#ebdc95"}, "reason": "Approved contrast"}}
                if source == "unparsed desktop":
                    self.css += '\n:root[data-theme="notepad"] { --hover: var(--accent); }'
                if source == "unparsed ios":
                    self.swift = self.swift.replace('case .paper:', 'case .notepad : makePalette()\ncase .paper:')
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("notepad", result.stdout)
                self.file["rules"]["style.palette"].pop("differs", None)

    def test_palette_difference_with_reason_passes(self):
        self.add_palette_rule()
        self.swift = self.swift.replace('0xe5ddcc', '0x123456')
        self.file["rules"]["style.palette"]["differs"] = {"ios": {"expect": {"paper.hover": "#123456"}, "reason": "Approved contrast"}}
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_palette_field_without_desktop_token_fails(self):
        self.add_palette_rule()
        self.swift = self.swift.replace('surfaceRaised:', 'rule:')
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("paper.rule: desktop", result.stdout)

    def test_new_rule_shapes(self):
        cases = [
            ("search.start", {"offered": True}, True),
            ("search.topics", {"offered": False}, True),
            ("search.x", {"offered": "true"}, False),
            ("search.x", {"label": "Anywhere"}, False),
            ("failure.x", {"message": "Failed."}, True),
            ("failure.x", {"message": ""}, False),
            ("editor.x", {"message": "Empty"}, True),
            ("editor.x", {"label": "Save"}, True),
            ("editor.x", {"actions": ["Keep Editing", "Discard"]}, True),
            ("editor.x", {"offered": False}, True),
            ("editor.x", {}, False),
            ("editor.x", {"offered": "false"}, False),
            ("editor.x", {"typo": True}, False),
            ("style.palette", {"match": False}, False),
            ("style.palette", {"match": 1}, False),
        ]
        for id, expected, valid in cases:
            with self.subTest(id=id, expected=expected):
                self.file["rules"] = {id: {"summary": "Rule", "expect": expected}}
                self.desktop = f'behaviourTest("{id}", () => {{}});'
                self.ios = f'let expected = try Behaviour.rule("{id}")'
                result = self.run_check()
                self.assertEqual(result.returncode == 0, valid, result.stdout)

    def test_palette_override_shape(self):
        self.add_palette_rule()
        for platform, expected in [("macos", {"paper.hover": "#123456"}), ("ios", {"hover": "#123456"}), ("ios", {"paper.hover": "#12345678"}), ("ios", {"paper.hover": "red"}), ("ios", {})]:
            with self.subTest(platform=platform, expected=expected):
                self.file["rules"]["style.palette"]["differs"] = {platform: {"expect": expected, "reason": "Approved"}}
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0)

    def test_palette_optional_fields_compared_when_present(self):
        self.add_palette_rule()
        self.swift = self.swift.replace('surfaceRaised:', 'feedBar:')
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("paper.feedBar: desktop #f6f1e700 ios #fffcf6", result.stdout)
        self.css = self.css.replace('#f6f1e700', '#fffcf6')
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_palette_missing_or_unparsed_sources_fail(self):
        self.add_palette_rule()
        for css, swift in [("", self.swift), (self.css, ""), (self.css, 'case .paper: Palette(hover: .red)')]:
            with self.subTest(css=css, swift=swift):
                self.css, self.swift = css, swift
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0)

    def test_palette_cannot_silently_skip_an_unparsed_theme(self):
        self.add_palette_rule()
        self.swift += '\ncase .notepad: Palette(hover: Color(red: value()))'
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notepad", result.stdout)

    def test_good_file_passes(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_test_names_rule_and_platform(self):
        self.ios = ""
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notice.copied_text ios", result.stdout)

    def test_missing_desktop_test_names_both_platforms(self):
        self.desktop = ""
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        for platform in ["macos", "windows"]:
            self.assertIn("notice.copied_text " + platform, result.stdout)

    def test_override_requires_reason(self):
        self.file["rules"]["notice.copied_text"]["differs"] = {"ios": {"expect": {"message": "Copied"}}}
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notice.copied_text ios", result.stdout)
        self.assertIn("reason", result.stdout)

    def test_blank_reason_is_rejected(self):
        self.file["rules"]["notice.copied_text"]["differs"] = {"ios": {"expect": {"message": "Copied"}, "reason": "  "}}
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_reasoned_override_passes(self):
        self.file["rules"]["notice.copied_text"]["differs"] = {"ios": {"expect": {"message": "Copied"}, "reason": "An approved difference"}}
        self.assertEqual(self.run_check().returncode, 0)

    def test_unknown_rule_fails(self):
        self.desktop += '\nbehaviourTest("notice.unknown", () => {});'
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notice.unknown", result.stdout)

    def test_comments_do_not_count(self):
        self.desktop = '// ' + self.desktop
        self.ios = '/* ' + self.ios + ' */'
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        for platform in ["macos", "windows", "ios"]:
            self.assertIn("notice.copied_text " + platform, result.stdout)

    def test_unknown_keys_and_platforms_fail(self):
        mutations = [
            lambda: self.file.update(typo=True),
            lambda: self.file.update(platforms=["macos", "windows", "android"]),
            lambda: self.file["rules"]["notice.copied_text"].update(typo=True),
            lambda: self.file["rules"]["notice.copied_text"]["expect"].update(typo=True),
            lambda: self.file["rules"]["notice.copied_text"].update(differs={"android": {"expect": {"message": "x"}, "reason": "x"}}),
            lambda: self.file["rules"]["notice.copied_text"].update(differs={"ios": {"expect": {"message": "x"}, "reason": "x", "typo": True}}),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                saved = json.loads(json.dumps(self.file))
                mutate()
                self.assertNotEqual(self.run_check().returncode, 0)
                self.file = saved

    def test_strings_do_not_count(self):
        self.desktop = 'const example = `' + self.desktop + '`;'
        self.ios = 'let example = "Behaviour.rule(\\"notice.copied_text\\")"'
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        for platform in ["macos", "windows", "ios"]:
            self.assertIn("notice.copied_text " + platform, result.stdout)

    def test_unknown_swift_rule_fails(self):
        self.ios += '\nlet unknown = try Behaviour.rule("notice.unknown")'
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notice.unknown ios", result.stdout)

    def test_dynamic_rule_ids_fail(self):
        self.desktop = 'behaviourTest(ruleID, () => {});'
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("literal rule ID", result.stdout)

    def test_duration_and_copy_shapes(self):
        cases = [
            ("composer.clear", {"offered": True, "label": "Clear draft"}, True),
            ("composer.clear", {"offered": True}, False),
            ("composer.pending_imports", {"offered": True, "label": "1 import pending", "message": "{count} imports pending"}, True),
            ("composer.pending_imports", {"label": "1 import pending", "message": "{count} imports pending"}, False),
            ("composer.pending_imports", {"offered": "yes", "label": "one", "message": "many"}, False),
            ("notice.duration", {"duration_seconds": 4}, True),
            ("notice.duration", {"duration_seconds": True}, False),
            ("notice.duration", {"duration_seconds": 0}, False),
            ("copy.inbox", {"menu": [{"id": "text", "label": "Copy Text"}], "row": False, "batch": []}, True),
            ("copy.inbox", {"menu": [{"id": "text", "label": "Copy Text", "typo": True}], "row": False, "batch": []}, False),
            ("copy.inbox", {"menu": [{"id": "unknown", "label": "Copy"}], "row": False, "batch": []}, False),
        ]
        for id, expected, valid in cases:
            with self.subTest(id=id, expected=expected):
                self.file["rules"] = {id: {"summary": "A rule", "expect": expected}}
                self.desktop = f'behaviourTest("{id}", () => {{}});'
                self.ios = f'let expected = try Behaviour.rule("{id}")'
                result = self.run_check()
                self.assertEqual(result.returncode == 0, valid, result.stdout)

    def test_notice_can_be_absent_with_reason(self):
        rule = self.file["rules"]["notice.copied_text"]
        rule["expect"]["offered"] = True
        rule["differs"] = {"ios": {"expect": {"offered": False}, "reason": "Native sharing has no callback"}}
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_notice_offered_must_be_boolean(self):
        self.file["rules"]["notice.copied_text"]["expect"]["offered"] = "no"
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_empty_inventory_fails(self):
        self.file["rules"] = {}
        self.desktop = self.ios = ""
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_malformed_expectations_fail(self):
        for expected in [{}, {"message": "x"}, {"message": "x", "buttons": "close"}, {"message": "x", "buttons": ["unknown"]}]:
            with self.subTest(expected=expected):
                self.file["rules"]["notice.copied_text"]["expect"] = expected
                self.assertNotEqual(self.run_check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
