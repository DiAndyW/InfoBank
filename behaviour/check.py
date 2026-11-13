import argparse
import json
from pathlib import Path
import re
import sys


PLATFORMS = {"macos", "windows", "ios"}
TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`|[A-Za-z_]\w*|[^\s]')


def keys(value, allowed, required, where):
    if not isinstance(value, dict) or set(value) - allowed or required - set(value):
        raise ValueError(f"{where}: expected keys {sorted(allowed)}, required {sorted(required)}")


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def expectation(value, where, fields, partial=False):
    required = fields - {"offered"} if "message" in fields else fields
    keys(value, fields, set() if partial else required, where)
    if not value:
        raise ValueError(f"{where}: empty expectation")
    for key, entry in value.items():
        valid = False
        if key in {"message", "label"}:
            valid = nonempty(entry)
        elif key in {"offered", "row"}:
            valid = isinstance(entry, bool)
        elif key == "duration_seconds":
            valid = type(entry) in (int, float) and 0 < entry < float("inf")
        elif key == "buttons":
            valid = isinstance(entry, list) and bool(entry) and all(button in {"Show", "Undo", "close"} for button in entry) and len(set(entry)) == len(entry) and "close" in entry
        elif key in {"menu", "batch"}:
            if isinstance(entry, list):
                for action in entry:
                    keys(action, {"id", "label"}, {"id", "label"}, where)
                    if action["id"] not in {"item", "text", "items"} or not nonempty(action["label"]):
                        raise ValueError(f"{where}: invalid copy action")
                valid = len({action["id"] for action in entry}) == len(entry)
        if not valid:
            raise ValueError(f"{where}: invalid {key}")


def validate(file):
    keys(file, {"platforms", "rules"}, {"platforms", "rules"}, "file")
    if not isinstance(file["platforms"], list) or len(file["platforms"]) != 3 or set(file["platforms"]) != PLATFORMS:
        raise ValueError("platforms: expected macos, windows, ios exactly once")
    rules = file["rules"]
    if not isinstance(rules, dict) or not rules:
        raise ValueError("rules: expected a non-empty object")
    for id, rule in rules.items():
        if not re.fullmatch(r'(notice|copy)\.[a-z][a-z0-9_]*', id):
            raise ValueError(f"{id}: invalid rule ID")
        keys(rule, {"summary", "expect", "differs"}, {"summary", "expect"}, id)
        if not nonempty(rule["summary"]):
            raise ValueError(f"{id}: summary is required")
        if id == "notice.duration":
            fields = {"duration_seconds"}
        elif id.startswith("notice."):
            fields = {"message", "buttons", "offered"}
        elif isinstance(rule["expect"], dict) and "menu" in rule["expect"]:
            fields = {"menu", "row", "batch"}
        else:
            fields = {"offered", "label"} if isinstance(rule["expect"], dict) and "label" in rule["expect"] else {"offered"}
        expectation(rule["expect"], id, fields)
        differs = rule.get("differs", {})
        keys(differs, PLATFORMS, set(), id + " differs")
        for platform, override in differs.items():
            where = f"{id} {platform}"
            keys(override, {"expect", "reason"}, {"expect", "reason"}, where)
            if not nonempty(override["reason"]):
                raise ValueError(f"{where}: reason must be non-empty")
            expectation(override["expect"], where, fields, partial=True)
    return rules


def references(source, swift):
    tokens = [match.group() for match in TOKEN.finditer(source) if not match.group().startswith(("//", "/*"))]
    prefix = ["Behaviour", ".", "rule", "("] if swift else ["behaviourTest", "("]
    for index in range(len(tokens) - len(prefix)):
        if tokens[index:index + len(prefix)] == prefix:
            literal = tokens[index + len(prefix)]
            if literal[:1] not in {'"', "'"} or "\\" in literal:
                raise ValueError("rule helper requires a literal rule ID")
            yield literal[1:-1]


def check(root):
    rules = validate(json.loads((root / "behaviour/behaviour.json").read_text()))
    covered = set()
    errors = []
    sources = [(path, False) for path in (root / "desktop/src").rglob("*.test.ts*") if path.suffix in {".ts", ".tsx"}]
    sources += [(path, True) for path in (root / "ios/NoteBankKit/Tests").rglob("*.swift")]
    for path, swift in sources:
        for id in references(path.read_text(), swift):
            platforms = {"ios"} if swift else {"macos", "windows"}
            for platform in sorted(platforms):
                if id not in rules:
                    errors.append(f"{id} {platform}: unknown rule in {path.relative_to(root)}")
                else:
                    covered.add((id, platform))
    for id in rules:
        for platform in sorted(PLATFORMS):
            if (id, platform) not in covered:
                errors.append(f"{id} {platform}: missing test")
    if errors:
        print("\n".join(errors))
        return 1
    for id, platform in sorted(covered):
        print(f"{id} {platform}: covered")
    print(f"{len(rules)} rules, {len(covered)} rule/platform pairs covered")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        return check(args.root)
    except (ValueError, OSError, TypeError) as error:
        print(error)
        return 1


if __name__ == "__main__":
    sys.exit(main())
