#!/usr/bin/env python3
"""Build an isolated app around the Item selection and drive it with XCTest."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
device = sys.argv[1] if len(sys.argv) > 1 else "0456EFE1-17C1-4C9D-BE64-33FFBF4E7386"

def encode(value):
    if isinstance(value, dict):
        return "{ " + " ".join(f"{key} = {encode(item)};" for key, item in value.items()) + " }"
    if isinstance(value, list):
        return "( " + ", ".join(encode(item) for item in value) + " )"
    return json.dumps(str(value))

with tempfile.TemporaryDirectory(prefix="notebank-selection-ui-") as temporary:
    root = Path(temporary)
    project = root / "Selection.xcodeproj"
    project.mkdir()
    toolbar = (repo / "ios/NoteBank/ItemSelectionView.swift").read_text().split("struct BatchActionsBar: View {", 1)[1].split("struct ItemNoticeView: View {", 1)[0]
    (root / "Toolbar.swift").write_text('''import NoteBankKit
import SwiftUI
@Observable @MainActor final class BatchItemActions {
    let selection = ItemSelection()
    var busy = false
    func copy(_ ids: [String], trash: Bool) {}
    func run(_ ids: [String], restore: Bool = false) {}
}
struct BatchActionsBar: View {''' + toolbar)
    objects = {}
    def add(key, **values):
        objects[key] = values
        return key
    files = []
    for key, path in [("Row", "ios/NoteBank/SelectableItemRow.swift"), ("Theme", "ios/NoteBank/Theme.swift"), ("App", "ios/SelectionChecks/HostApp.swift"), ("Test", "ios/SelectionChecks/UITests.swift")]:
        add(key, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(repo / path), sourceTree="<absolute>")
        files.append(key)
        add(key + "Build", isa="PBXBuildFile", fileRef=key)
    add("Toolbar", isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(root / "Toolbar.swift"), sourceTree="<absolute>")
    files.append("Toolbar")
    add("ToolbarBuild", isa="PBXBuildFile", fileRef="Toolbar")
    add("KitPackage", isa="XCLocalSwiftPackageReference", relativePath=str(repo / "ios/NoteBankKit"))
    add("KitProduct", isa="XCSwiftPackageProductDependency", package="KitPackage", productName="NoteBankKit")
    add("KitBuild", isa="PBXBuildFile", productRef="KitProduct")
    add("AppProduct", isa="PBXFileReference", explicitFileType="wrapper.application", path="SelectionHost.app", sourceTree="BUILT_PRODUCTS_DIR")
    add("TestProduct", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="SelectionUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    add("Group", isa="PBXGroup", children=files + ["Products"], sourceTree="<group>")
    add("Products", isa="PBXGroup", children=["AppProduct", "TestProduct"], name="Products", sourceTree="<group>")
    settings = dict(SDKROOT="iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="26.0", SWIFT_VERSION="6.0", ONLY_ACTIVE_ARCH="YES", CODE_SIGN_IDENTITY="-", CODE_SIGNING_ALLOWED="YES", GENERATE_INFOPLIST_FILE="YES", TARGETED_DEVICE_FAMILY="1,2", ALWAYS_SEARCH_USER_PATHS="NO")
    add("ProjectConfig", isa="XCBuildConfiguration", name="Debug", buildSettings=settings)
    add("ProjectConfigs", isa="XCConfigurationList", buildConfigurations=["ProjectConfig"], defaultConfigurationName="Debug")
    for name in ["App", "Test"]:
        target_settings = dict(PRODUCT_NAME="SelectionHost" if name == "App" else "SelectionUITests", PRODUCT_BUNDLE_IDENTIFIER="app.notebank.selection-ui" + (".tests" if name == "Test" else ""))
        if name == "Test":
            target_settings["TEST_TARGET_NAME"] = "SelectionHost"
        else:
            target_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
            target_settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
        add(name + "Config", isa="XCBuildConfiguration", name="Debug", buildSettings=target_settings)
        add(name + "Configs", isa="XCConfigurationList", buildConfigurations=[name + "Config"], defaultConfigurationName="Debug")
        add(name + "Sources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=["RowBuild", "ThemeBuild", "AppBuild", "ToolbarBuild"] if name == "App" else ["TestBuild"], runOnlyForDeploymentPostprocessing="0")
        add(name + "Frameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=["KitBuild"] if name == "App" else [], runOnlyForDeploymentPostprocessing="0")
        add(name + "Target", isa="PBXNativeTarget", name="SelectionHost" if name == "App" else "SelectionUITests", productName="SelectionHost" if name == "App" else "SelectionUITests", productType="com.apple.product-type.application" if name == "App" else "com.apple.product-type.bundle.ui-testing", productReference=name + "Product", buildConfigurationList=name + "Configs", buildPhases=[name + "Sources", name + "Frameworks"], buildRules=[], packageProductDependencies=["KitProduct"] if name == "App" else [], dependencies=[] if name == "App" else ["Dependency"])
    add("Proxy", isa="PBXContainerItemProxy", containerPortal="Project", proxyType="1", remoteGlobalIDString="AppTarget", remoteInfo="SelectionHost")
    add("Dependency", isa="PBXTargetDependency", target="AppTarget", targetProxy="Proxy")
    add("Project", isa="PBXProject", buildConfigurationList="ProjectConfigs", compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en"], mainGroup="Group", productRefGroup="Products", projectDirPath="", targets=["AppTarget", "TestTarget"], packageReferences=["KitPackage"], attributes=dict(LastUpgradeCheck="2600", TargetAttributes=dict(TestTarget=dict(TestTargetID="AppTarget"))))
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject="Project")))
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)
    (schemes / "Selection.xcscheme").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.3"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppTarget" BuildableName="SelectionHost.app" BlueprintName="SelectionHost" ReferencedContainer="container:Selection.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TestTarget" BuildableName="SelectionUITests.xctest" BlueprintName="SelectionUITests" ReferencedContainer="container:Selection.xcodeproj"/></TestableReference></Testables></TestAction></Scheme>''')
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))["devices"]
    started = not any(d["udid"] == device and d["state"] == "Booted" for group in devices.values() for d in group)
    if started:
        subprocess.run(["xcrun", "simctl", "boot", device], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    try:
        result = str(root / "Selection.xcresult")
        subprocess.run(["xcodebuild", "test", "-project", str(project), "-scheme", "Selection", "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(root / "build"), "-resultBundlePath", result, "-parallel-testing-enabled", "NO"], check=True)
        summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result], text=True))
        assert summary["totalTestCount"] == 4 and summary["passedTests"] == 4, summary
        print("4 Item selection UI tests passed: compact toolbar, exchanged action slot, hold, add, final deselection, normal tap, and scrolling")
    finally:
        for identifier in ["app.notebank.selection-ui", "app.notebank.selection-ui.tests.xctrunner"]:
            subprocess.run(["xcrun", "simctl", "uninstall", device, identifier], check=False)
        if started:
            subprocess.run(["xcrun", "simctl", "shutdown", device], check=False)
