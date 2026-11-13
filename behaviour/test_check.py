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
        self.desktop = 'behaviourTest("notice.copied_text", expected => expect(message).toBe(expected.message));'
        self.ios = 'let expected = try Behaviour.rule("notice.copied_text")'

    def run_check(self):
        (self.root / "behaviour").mkdir(exist_ok=True)
        (self.root / "behaviour/behaviour.json").write_text(json.dumps(self.file))
        (self.root / "desktop/src").mkdir(parents=True, exist_ok=True)
        (self.root / "desktop/src/Flow.test.tsx").write_text(self.desktop)
        (self.root / "ios/NoteBankKit/Tests").mkdir(parents=True, exist_ok=True)
        (self.root / "ios/NoteBankKit/Tests/FlowTests.swift").write_text(self.ios)
        return subprocess.run([sys.executable, str(Path(__file__).with_name("check.py")), "--root", str(self.root)], capture_output=True, text=True)

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
