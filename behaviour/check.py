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
    required = fields - {"offered"} if "message" in fields and where.startswith("notice.") else fields
    keys(value, fields, set() if partial else required, where)
    if not value:
        raise ValueError(f"{where}: empty expectation")
    for key, entry in value.items():
        valid = False
        if key in {"message", "label"}:
            valid = nonempty(entry)
        elif key in {"offered", "row"}:
            valid = isinstance(entry, bool)
        elif key in {"initial_items", "older_items"}:
            valid = type(entry) is int and entry > 0
        elif key == "order":
            valid = entry == "input"
        elif key == "match":
            valid = entry is True
        elif key == "actions":
            valid = isinstance(entry, list) and bool(entry) and all(nonempty(action) for action in entry) and len(set(entry)) == len(entry)
            if valid and where.startswith("item."):
                valid = all(action in {"edit", "move", "copy_item", "copy_text", "trash"} for action in entry)
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
        if not re.fullmatch(r'(notice|copy|failure|editor|item|feed|search|composer|style)\.[a-z][a-z0-9_]*', id):
            raise ValueError(f"{id}: invalid rule ID")
        keys(rule, {"summary", "expect", "differs"}, {"summary", "expect"}, id)
        if not nonempty(rule["summary"]):
            raise ValueError(f"{id}: summary is required")
        if id == "notice.duration":
            fields = {"duration_seconds"}
        elif id.startswith("notice."):
            fields = {"message", "buttons", "offered"}
        elif id.startswith("failure."):
            fields = {"message"}
        elif id == "feed.opening":
            fields = {"initial_items", "older_items"}
        elif id == "composer.attachment_order":
            fields = {"order"}
        elif id == "composer.clear":
            fields = {"offered", "label"}
        elif id == "composer.pending_imports":
            fields = {"offered", "message", "label"}
        elif id == "search.activity":
            fields = {"offered", "label", "message"}
        elif id.startswith(("search.", "composer.")):
            fields = {"offered"}
        elif id == "item.move_to_current":
            fields = {"offered"}
        elif id.startswith("item."):
            fields = {"actions"}
        elif id.startswith("editor."):
            fields = {"message", "label", "actions", "offered"}
        elif id == "style.palette":
            fields = {"match"}
        elif id.startswith("style."):
            raise ValueError(f"{id}: unsupported style rule")
        elif isinstance(rule["expect"], dict) and "menu" in rule["expect"]:
            fields = {"menu", "row", "batch"}
        else:
            fields = {"offered", "label"} if isinstance(rule["expect"], dict) and "label" in rule["expect"] else {"offered"}
        expectation(rule["expect"], id, fields, partial=id.startswith("editor."))
        differs = rule.get("differs", {})
        keys(differs, PLATFORMS, set(), id + " differs")
        for platform, override in differs.items():
            where = f"{id} {platform}"
            keys(override, {"expect", "reason"}, {"expect", "reason"}, where)
            if not nonempty(override["reason"]):
                raise ValueError(f"{where}: reason must be non-empty")
            if id == "style.palette":
                if platform != "ios" or not isinstance(override["expect"], dict) or not override["expect"]:
                    raise ValueError(f"{where}: expected iOS palette differences")
                for field, colour in override["expect"].items():
                    if not re.fullmatch(r"[a-z][a-z0-9_]*\.[a-z][A-Za-z0-9]*", field) or not isinstance(colour, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", colour):
                        raise ValueError(f"{where}: invalid palette difference {field}")
            else:
                expectation(override["expect"], where, fields, partial=True)
    return rules


def palette(root, rule):
    css = re.sub(r"/\*[\s\S]*?\*/", "", (root / "desktop/src/tokens.css").read_text())
    swift = re.sub(r"//[^\n]*|/\*[\s\S]*?\*/", "", (root / "ios/NoteBank/Theme.swift").read_text())
    desktop = {}
    for theme, body in re.findall(r':root\[data-theme="([a-z][a-z0-9_]*)"\]\s*\{([^}]*)\}', css):
        desktop[theme] = {name: colour.lower() for name, colour in re.findall(r"--([a-z][a-z0-9-]*)\s*:\s*(#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?)\s*;", body)}
    palettes = re.findall(r"case\s+\.([a-z][a-z0-9_]*)\s*:\s*Palette\s*\(((?:[^()]|\([^()]*\))*)\)", swift)
    theme_enum = re.search(r"\benum\s+Theme\b[^{]*\{([^}]*)\}", swift)
    enum_themes = set()
    if theme_enum:
        for declaration in re.findall(r"^\s*case\s+([a-z][a-z0-9_]*(?:\s*,\s*[a-z][a-z0-9_]*)*)\s*$", theme_enum[1], re.MULTILINE):
            enum_themes.update(name.strip() for name in declaration.split(","))
    css_themes = set(re.findall(r':root\[data-theme="([a-z][a-z0-9_]*)"\]', css))
    overrides = rule.get("differs", {}).get("ios", {}).get("expect", {})
    seen = set()
    parsed_themes = {theme for theme, _ in palettes}
    declared_themes = set(re.findall(r"case\s+\.([a-z][a-z0-9_]*)\s*:", swift))
    errors = [] if enum_themes else ["style.palette: no Theme enum cases found"]
    for theme in sorted(enum_themes | css_themes | declared_themes | parsed_themes):
        if theme not in enum_themes:
            errors.append(f"style.palette {theme}: missing Theme enum case")
        if not desktop.get(theme):
            errors.append(f"style.palette {theme}: missing or unparsed desktop palette")
        if theme not in parsed_themes:
            errors.append(f"style.palette {theme}: missing or unparsed iOS palette")
    field_pattern = r"([a-z][A-Za-z0-9]*)\s*:\s*Color\(0x([0-9a-fA-F]{6})\)"
    for theme, body in palettes:
        fields = re.findall(field_pattern, body)
        if not fields or re.sub(field_pattern, "", body).strip(" \t\r\n,"):
            errors.append(f"style.palette {theme}: unsupported palette colour")
        for field, colour_hex in fields:
            name = f"{theme}.{field}"
            seen.add(name)
            token = re.sub(r"[A-Z]", lambda match: "-" + match.group().lower(), field)
            colour = "#" + colour_hex.lower()
            actual = desktop.get(theme, {}).get(token)
            expected = overrides.get(name, actual)
            if actual is None or colour != expected.lower():
                errors.append(f"{name}: desktop {actual or 'missing'} ios {colour}")
    for name in overrides.keys() - seen:
        errors.append(f"{name}: unknown iOS palette field")
    return errors


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
    errors = palette(root, rules["style.palette"]) if "style.palette" in rules else []
    covered.update((id, platform) for id in rules if id.startswith("style.") for platform in PLATFORMS)
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
