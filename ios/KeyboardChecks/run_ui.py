#!/usr/bin/env python3
"""Drive the installed signed NoteBank app with XCTest."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import sqlite3
from urllib.parse import urlparse

repo = Path(__file__).resolve().parents[2]
device = sys.argv[1] if len(sys.argv) > 1 else "0456EFE1-17C1-4C9D-BE64-33FFBF4E7386"

def encode(value):
    if isinstance(value, dict):
        return "{ " + " ".join(f"{key} = {encode(item)};" for key, item in value.items()) + " }"
    if isinstance(value, list):
        return "( " + ", ".join(encode(item) for item in value) + " )"
    return json.dumps(str(value))

groups = subprocess.check_output(["xcrun", "simctl", "get_app_container", device, "app.notebank.ios", "groups"], text=True)
group = next(line.split("\t", 1)[1] for line in groups.splitlines() if line.startswith("group.app.notebank\t"))
with sqlite3.connect(Path(group) / "Library/Application Support/NoteBank/notebank.db") as database:
    server = database.execute("SELECT server_url FROM device").fetchone()[0]
    assert urlparse(server).hostname in {"127.0.0.1", "localhost", "::1"}, "Use a disposable simulator configured with a loopback Server"
    database.execute("INSERT OR REPLACE INTO drafts(place, text) VALUES ('home', ?)", ("Long draft text. " * 400,))
    database.execute("UPDATE settings SET trash_after_copy = 0")

with tempfile.TemporaryDirectory(prefix="notebank-keyboard-ui-") as temporary:
    root = Path(temporary)
    project = root / "Keyboard.xcodeproj"
    project.mkdir()
    objects = {}
    def add(key, **values):
        objects[key] = values
        return key
    files = []
    for key, path in [("App", "ios/KeyboardChecks/HostApp.swift"), ("Test", "ios/KeyboardChecks/UITests.swift")]:
        add(key, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(repo / path), sourceTree="<absolute>")
        files.append(key)
        add(key + "Build", isa="PBXBuildFile", fileRef=key)
    add("AppProduct", isa="PBXFileReference", explicitFileType="wrapper.application", path="KeyboardHost.app", sourceTree="BUILT_PRODUCTS_DIR")
    add("TestProduct", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="KeyboardUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    add("Group", isa="PBXGroup", children=files + ["Products"], sourceTree="<group>")
    add("Products", isa="PBXGroup", children=["AppProduct", "TestProduct"], name="Products", sourceTree="<group>")
    settings = dict(SDKROOT="iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="26.0", SWIFT_VERSION="6.0", ONLY_ACTIVE_ARCH="YES", CODE_SIGN_IDENTITY="-", CODE_SIGNING_ALLOWED="YES", GENERATE_INFOPLIST_FILE="YES", TARGETED_DEVICE_FAMILY="1,2", ALWAYS_SEARCH_USER_PATHS="NO")
    add("ProjectConfig", isa="XCBuildConfiguration", name="Debug", buildSettings=settings)
    add("ProjectConfigs", isa="XCConfigurationList", buildConfigurations=["ProjectConfig"], defaultConfigurationName="Debug")
    for name in ["App", "Test"]:
        target_settings = dict(PRODUCT_NAME="KeyboardHost" if name == "App" else "KeyboardUITests", PRODUCT_BUNDLE_IDENTIFIER="app.notebank.keyboard-ui" + (".tests" if name == "Test" else ""))
        if name == "Test":
            target_settings["TEST_TARGET_NAME"] = "KeyboardHost"
        else:
            target_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
            target_settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
        add(name + "Config", isa="XCBuildConfiguration", name="Debug", buildSettings=target_settings)
        add(name + "Configs", isa="XCConfigurationList", buildConfigurations=[name + "Config"], defaultConfigurationName="Debug")
        add(name + "Sources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=["AppBuild"] if name == "App" else ["TestBuild"], runOnlyForDeploymentPostprocessing="0")
        add(name + "Frameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
        add(name + "Target", isa="PBXNativeTarget", name="KeyboardHost" if name == "App" else "KeyboardUITests", productName="KeyboardHost" if name == "App" else "KeyboardUITests", productType="com.apple.product-type.application" if name == "App" else "com.apple.product-type.bundle.ui-testing", productReference=name + "Product", buildConfigurationList=name + "Configs", buildPhases=[name + "Sources", name + "Frameworks"], buildRules=[], packageProductDependencies=[], dependencies=[] if name == "App" else ["Dependency"])
    add("Proxy", isa="PBXContainerItemProxy", containerPortal="Project", proxyType="1", remoteGlobalIDString="AppTarget", remoteInfo="KeyboardHost")
    add("Dependency", isa="PBXTargetDependency", target="AppTarget", targetProxy="Proxy")
    add("Project", isa="PBXProject", buildConfigurationList="ProjectConfigs", compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en"], mainGroup="Group", productRefGroup="Products", projectDirPath="", targets=["AppTarget", "TestTarget"], packageReferences=[], attributes=dict(LastUpgradeCheck="2600", TargetAttributes=dict(TestTarget=dict(TestTargetID="AppTarget"))))
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject="Project")))
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)
    (schemes / "Keyboard.xcscheme").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.3"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppTarget" BuildableName="KeyboardHost.app" BlueprintName="KeyboardHost" ReferencedContainer="container:Keyboard.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TestTarget" BuildableName="KeyboardUITests.xctest" BlueprintName="KeyboardUITests" ReferencedContainer="container:Keyboard.xcodeproj"/></TestableReference></Testables></TestAction></Scheme>''')
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))["devices"]
    started = not any(d["udid"] == device and d["state"] == "Booted" for group in devices.values() for d in group)
    if started:
        subprocess.run(["xcrun", "simctl", "boot", device], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    try:
        result = str(root / "Keyboard.xcresult")
        subprocess.run(["xcodebuild", "test", "-project", str(project), "-scheme", "Keyboard", "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", "/tmp/notebank-keyboard-ui-build", "-resultBundlePath", result, "-parallel-testing-enabled", "NO"], check=True)
        summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result], text=True))
        assert summary["totalTestCount"] == 2 and summary["passedTests"] == 2, summary
        print("2 keyboard/lifecycle checks passed")
    finally:
        for identifier in ["app.notebank.ios", "app.notebank.keyboard-ui", "app.notebank.keyboard-ui.tests.xctrunner"]:
            subprocess.run(["xcrun", "simctl", "uninstall", device, identifier], check=False)
        if started:
            subprocess.run(["xcrun", "simctl", "shutdown", device], check=False)
