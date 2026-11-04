#!/usr/bin/env python3
"""Drive the quick action and the Capture Control on a simulator and check they open the focused composer."""
from pathlib import Path
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import tempfile
import time
import threading

repo = Path(__file__).resolve().parents[2]
app_id = "app.notebank.ios"
host_id = "app.notebank.quick-capture-check"

if len(sys.argv) not in (2, 3):
    sys.exit("usage: run_ui.py <simulator UDID> [test method]")
device = sys.argv[1]
selected = sys.argv[2] if len(sys.argv) == 3 else None

def encode(value):
    if isinstance(value, dict):
        return "{ " + " ".join(f"{key} = {encode(item)};" for key, item in value.items()) + " }"
    if isinstance(value, list):
        return "( " + ", ".join(encode(item) for item in value) + " )"
    return json.dumps(str(value))

def simctl(*args, check=True):
    return subprocess.run(["xcrun", "simctl", *args], check=check, capture_output=True, text=True).stdout.strip()

class CheckHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        authorized = self.headers.get("Authorization") == "Bearer check-secret"
        self.send_response(204 if self.path == "/auth/check" and authorized else 503)
        self.end_headers()

    def do_POST(self):
        self.send_response(503)
        self.end_headers()

    def log_message(self, *_args):
        pass


def generate_project(project, server_url):
    project.mkdir()
    objects = {}
    def add(key, **values):
        objects[key] = values
        return key
    files = []
    for key, path in [("App", "ios/QuickCaptureChecks/HostApp.swift"), ("Test", "ios/QuickCaptureChecks/UITests.swift")]:
        add(key, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(repo / path), sourceTree="<absolute>")
        files.append(key)
        add(key + "Build", isa="PBXBuildFile", fileRef=key)
    add("AppProduct", isa="PBXFileReference", explicitFileType="wrapper.application", path="CaptureHost.app", sourceTree="BUILT_PRODUCTS_DIR")
    add("TestProduct", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="CaptureUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    add("Group", isa="PBXGroup", children=files + ["Products"], sourceTree="<group>")
    add("Products", isa="PBXGroup", children=["AppProduct", "TestProduct"], name="Products", sourceTree="<group>")
    settings = dict(SDKROOT="iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="26.0", SWIFT_VERSION="6.0", CODE_SIGN_IDENTITY="-", CODE_SIGNING_ALLOWED="YES", GENERATE_INFOPLIST_FILE="YES", TARGETED_DEVICE_FAMILY="1,2", ALWAYS_SEARCH_USER_PATHS="NO")
    add("ProjectConfig", isa="XCBuildConfiguration", name="Debug", buildSettings=settings)
    add("ProjectConfigs", isa="XCConfigurationList", buildConfigurations=["ProjectConfig"], defaultConfigurationName="Debug")
    for name in ["App", "Test"]:
        target_settings = dict(PRODUCT_NAME="CaptureHost" if name == "App" else "CaptureUITests", PRODUCT_BUNDLE_IDENTIFIER=host_id + (".tests" if name == "Test" else ""))
        if name == "Test":
            target_settings["TEST_TARGET_NAME"] = "CaptureHost"
        else:
            target_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
            target_settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
        add(name + "Config", isa="XCBuildConfiguration", name="Debug", buildSettings=target_settings)
        add(name + "Configs", isa="XCConfigurationList", buildConfigurations=[name + "Config"], defaultConfigurationName="Debug")
        add(name + "Sources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=[name + "Build"], runOnlyForDeploymentPostprocessing="0")
        add(name + "Frameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
        add(name + "Target", isa="PBXNativeTarget", name="CaptureHost" if name == "App" else "CaptureUITests", productName="CaptureHost" if name == "App" else "CaptureUITests", productType="com.apple.product-type.application" if name == "App" else "com.apple.product-type.bundle.ui-testing", productReference=name + "Product", buildConfigurationList=name + "Configs", buildPhases=[name + "Sources", name + "Frameworks"], buildRules=[], dependencies=[] if name == "App" else ["Dependency"])
    add("Proxy", isa="PBXContainerItemProxy", containerPortal="Project", proxyType="1", remoteGlobalIDString="AppTarget", remoteInfo="CaptureHost")
    add("Dependency", isa="PBXTargetDependency", target="AppTarget", targetProxy="Proxy")
    add("Project", isa="PBXProject", buildConfigurationList="ProjectConfigs", compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en"], mainGroup="Group", productRefGroup="Products", projectDirPath="", targets=["AppTarget", "TestTarget"], attributes=dict(LastUpgradeCheck="2600", TargetAttributes=dict(TestTarget=dict(TestTargetID="AppTarget"))))
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject="Project")))
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)
    (schemes / "Capture.xcscheme").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.3"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppTarget" BuildableName="CaptureHost.app" BlueprintName="CaptureHost" ReferencedContainer="container:Capture.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TestTarget" BuildableName="CaptureUITests.xctest" BlueprintName="CaptureUITests" ReferencedContainer="container:Capture.xcodeproj"/></TestableReference></Testables><EnvironmentVariables><EnvironmentVariable key="NOTEBANK_TEST_SERVER" value="SERVER_URL" isEnabled="YES"/></EnvironmentVariables></TestAction></Scheme>'''.replace("SERVER_URL", server_url))

with ThreadingHTTPServer(("127.0.0.1", 0), CheckHandler) as check_server, tempfile.TemporaryDirectory(prefix="notebank-quick-capture-ui-") as temporary:
    threading.Thread(target=check_server.serve_forever, daemon=True).start()
    root = Path(temporary)
    try:
        simctl("shutdown", device, check=False)
        simctl("boot", device)
        simctl("bootstatus", device, "-b")
        simctl("uninstall", device, app_id, check=False)

        subprocess.run(["xcodebuild", "-project", str(repo / "ios/NoteBank.xcodeproj"), "-scheme", "NoteBank", "-destination", f"id={device}", "-derivedDataPath", str(root / "app"), "-quiet", "build"], check=True)
        simctl("install", device, str(root / "app/Build/Products/Debug-iphonesimulator/NoteBank.app"))
        simctl("launch", device, app_id)
        time.sleep(5)
        simctl("terminate", device, app_id)

        generate_project(root / "Capture.xcodeproj", f"http://127.0.0.1:{check_server.server_port}")
        result = root / "result.xcresult"
        tests = subprocess.run(["xcodebuild", "test", "-project", str(root / "Capture.xcodeproj"), "-scheme", "Capture", "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(root / "ui"), "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "120"] + ([f"-only-testing:CaptureUITests/QuickCaptureUITests/{selected}"] if selected else []))
        summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], text=True))
        assert tests.returncode == 0, (summary["failedTests"], [failure["testIdentifierString"] + ": " + failure["failureText"] for failure in summary["testFailures"]])
        expected = 1 if selected else 4
        assert summary["totalTestCount"] == expected and summary["passedTests"] == expected, summary

        print(f"{expected} navigation and quick capture UI tests passed")
    finally:
        check_server.shutdown()
        simctl("uninstall", device, app_id, check=False)
        simctl("uninstall", device, host_id + ".tests.xctrunner", check=False)
        simctl("uninstall", device, host_id, check=False)
