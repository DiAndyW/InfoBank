#!/usr/bin/env python3
"""Run native paste checks in an isolated simulator app; never install NoteBank."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parents[2]
device = sys.argv[1] if len(sys.argv) > 1 else "booted"
identifier = "app.notebank.paste-checks"


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


with tempfile.TemporaryDirectory(prefix="notebank-paste-checks-") as temporary:
    app = Path(temporary) / "PasteChecks.app"
    app.mkdir()
    with (app / "Info.plist").open("wb") as output:
        plistlib.dump({
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "PasteChecks",
            "CFBundleName": "NoteBank Paste Checks",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
            "LSRequiresIPhoneOS": True,
            "UILaunchScreen": {},
        }, output)
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    environment = dict(os.environ, SDKROOT=sdk)
    architecture = run("uname", "-m")
    run("xcrun", "swiftc", "-sdk", sdk, "-target", f"{architecture}-apple-ios26.0-simulator",
        "-parse-as-library", "-module-cache-path", str(Path(tempfile.gettempdir()) / "notebank-paste-checks-module-cache"),
        *[str(repo / source) for source in [
            "ios/NoteBankKit/Sources/NoteBankKit/ItemClipboard.swift",
            "ios/NoteBank/AttachmentTextView.swift",
            "ios/NoteBank/ComposerInput.swift",
            "ios/NoteBank/Theme.swift",
            "ios/PasteChecks/Probe.swift",
        ]], "-o", str(app / "PasteChecks"), env=environment)
    run("codesign", "--force", "--sign", "-", str(app))
    installed = False
    try:
        run("xcrun", "simctl", "install", device, str(app))
        installed = True
        container = Path(run("xcrun", "simctl", "get_app_container", device, identifier, "data"))
        result = container / "Documents" / "result.json"
        if result.exists():
            result.unlink()
        run("xcrun", "simctl", "launch", "--terminate-running-process", device, identifier)
        deadline = time.monotonic() + 45
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        checks = json.loads(result.read_text())
        assert len(checks) == 7, checks
        for check in checks[:5]:
            assert check["completeWrite"] is True, check
            assert check["receivedNames"] == ["paste-check.jpg"] * check["count"], check
            assert check["canPaste"] is True, check
            assert len(check["received"]) == check["count"], check
            assert all(kind == "public.jpeg" for kind in check["received"]), check
            assert check["embedded"] == 0 and check["undoRestored"] is True, check
            assert check["text"] == ("before Test after" if check["caption"] else "before AFTER after"), check
        for check in checks[5:]:
            assert check["swiftUIBinding"] is True, check
            assert check["clearedAfterSend"] is True, check
            assert check["growsAndScrolls"] is True, check
            assert check["placeholderVisible"] is True, check
            assert check["height"] > 0, check
        print("7 native paste checks passed: text, 1/3 images, image-only, selection, Undo, original format and both composer layouts/bindings")
    finally:
        if installed:
            run("xcrun", "simctl", "uninstall", device, identifier)
