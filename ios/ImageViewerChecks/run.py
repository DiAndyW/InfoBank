#!/usr/bin/env python3
"""Exercise production viewer code in a separate simulator app; never install NoteBank."""
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
identifier = "app.notebank.image-viewer-checks"

def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()

with tempfile.TemporaryDirectory(prefix="notebank-image-viewer-checks-") as temporary:
    app = Path(temporary) / "ImageChecks.app"
    app.mkdir()
    with (app / "Info.plist").open("wb") as output:
        plistlib.dump(dict(CFBundleIdentifier=identifier, CFBundleExecutable="ImageChecks", CFBundleName="Image Checks", CFBundleVersion="1", CFBundlePackageType="APPL", LSRequiresIPhoneOS=True, UILaunchScreen={}), output)
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    run("xcrun", "swiftc", "-sdk", sdk, "-target", f"{run('uname', '-m')}-apple-ios26.0-simulator",
        "-parse-as-library", "-module-cache-path", "/tmp/notebank-paste-checks-module-cache",
        str(repo / "ios/NoteBank/ImageViewer.swift"), str(repo / "ios/ImageViewerChecks/Probe.swift"),
        "-o", str(app / "ImageChecks"), env=dict(os.environ, SDKROOT=sdk))
    run("codesign", "--force", "--sign", "-", str(app))
    installed = False
    try:
        run("xcrun", "simctl", "install", device, str(app))
        installed = True
        container = Path(run("xcrun", "simctl", "get_app_container", device, identifier, "data"))
        result = container / "Documents/result.json"
        result.unlink(missing_ok=True)
        run("xcrun", "simctl", "launch", "--terminate-running-process", device, identifier)
        deadline = time.monotonic() + 45
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        checks = json.loads(result.read_text())
        assert len(checks) == 10, checks
        print(f"{len(checks)} native image viewer checks passed")
        for check in checks:
            print("- " + check)
    finally:
        if installed:
            run("xcrun", "simctl", "uninstall", device, identifier)
