#!/usr/bin/env python3
"""Build an isolated gallery app and drive it with real XCTest gestures."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parents[2]
device = sys.argv[1] if len(sys.argv) > 1 else "31B64E72-AA4B-41B8-A790-DCDE5C17C88B"

def encode(value):
    if isinstance(value, dict):
        return "{ " + " ".join(f"{key} = {encode(item)};" for key, item in value.items()) + " }"
    if isinstance(value, list):
        return "( " + ", ".join(encode(item) for item in value) + " )"
    return json.dumps(str(value))

with tempfile.TemporaryDirectory(prefix="notebank-gallery-ui-") as temporary:
    root = Path(temporary)
    project = root / "Gallery.xcodeproj"
    project.mkdir()
    objects = {}
    def add(key, **values):
        objects[key] = values
        return key
    files = []
    for key, path in [("Viewer", "ios/NoteBank/ImageViewer.swift"), ("App", "ios/ImageViewerChecks/GalleryApp.swift"), ("Test", "ios/ImageViewerChecks/UITests.swift")]:
        add(key, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(repo / path), sourceTree="<absolute>")
        files.append(key)
        add(key + "Build", isa="PBXBuildFile", fileRef=key)
    add("AppProduct", isa="PBXFileReference", explicitFileType="wrapper.application", path="GalleryApp.app", sourceTree="BUILT_PRODUCTS_DIR")
    add("TestProduct", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="GalleryUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    add("Group", isa="PBXGroup", children=files + ["Products"], sourceTree="<group>")
    add("Products", isa="PBXGroup", children=["AppProduct", "TestProduct"], name="Products", sourceTree="<group>")
    settings = dict(SDKROOT="iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="26.0", SWIFT_VERSION="6.0", CODE_SIGN_IDENTITY="-", CODE_SIGNING_ALLOWED="YES", GENERATE_INFOPLIST_FILE="YES", TARGETED_DEVICE_FAMILY="1,2", ALWAYS_SEARCH_USER_PATHS="NO")
    add("ProjectConfig", isa="XCBuildConfiguration", name="Debug", buildSettings=settings)
    add("ProjectConfigs", isa="XCConfigurationList", buildConfigurations=["ProjectConfig"], defaultConfigurationName="Debug")
    for name in ["App", "Test"]:
        target_settings = dict(PRODUCT_NAME="GalleryApp" if name == "App" else "GalleryUITests", PRODUCT_BUNDLE_IDENTIFIER="app.notebank.gallery-ui" + (".tests" if name == "Test" else ""))
        if name == "Test":
            target_settings["TEST_TARGET_NAME"] = "GalleryApp"
        else:
            target_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
            target_settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
        add(name + "Config", isa="XCBuildConfiguration", name="Debug", buildSettings=target_settings)
        add(name + "Configs", isa="XCConfigurationList", buildConfigurations=[name + "Config"], defaultConfigurationName="Debug")
        add(name + "Sources", isa="PBXSourcesBuildPhase", buildActionMask="2147483647", files=["ViewerBuild", "AppBuild"] if name == "App" else ["TestBuild"], runOnlyForDeploymentPostprocessing="0")
        add(name + "Frameworks", isa="PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
        add(name + "Target", isa="PBXNativeTarget", name="GalleryApp" if name == "App" else "GalleryUITests", productName="GalleryApp" if name == "App" else "GalleryUITests", productType="com.apple.product-type.application" if name == "App" else "com.apple.product-type.bundle.ui-testing", productReference=name + "Product", buildConfigurationList=name + "Configs", buildPhases=[name + "Sources", name + "Frameworks"], buildRules=[], dependencies=[] if name == "App" else ["Dependency"])
    add("Proxy", isa="PBXContainerItemProxy", containerPortal="Project", proxyType="1", remoteGlobalIDString="AppTarget", remoteInfo="GalleryApp")
    add("Dependency", isa="PBXTargetDependency", target="AppTarget", targetProxy="Proxy")
    add("Project", isa="PBXProject", buildConfigurationList="ProjectConfigs", compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en"], mainGroup="Group", productRefGroup="Products", projectDirPath="", targets=["AppTarget", "TestTarget"], attributes=dict(LastUpgradeCheck="2600", TargetAttributes=dict(TestTarget=dict(TestTargetID="AppTarget"))))
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion="1", objectVersion="56", classes={}, objects=objects, rootObject="Project")))
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True)
    (schemes / "Gallery.xcscheme").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.3"><BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AppTarget" BuildableName="GalleryApp.app" BlueprintName="GalleryApp" ReferencedContainer="container:Gallery.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="TestTarget" BuildableName="GalleryUITests.xctest" BlueprintName="GalleryUITests" ReferencedContainer="container:Gallery.xcodeproj"/></TestableReference></Testables></TestAction></Scheme>''')
    try:
        result = f"/tmp/notebank-gallery-ui-{time.time_ns()}.xcresult"
        subprocess.run(["xcodebuild", "test", "-project", str(project), "-scheme", "Gallery", "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", "/tmp/notebank-gallery-ui-build", "-resultBundlePath", result, "-parallel-testing-enabled", "NO", "-quiet"], check=True)
        summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", result], text=True))
        assert summary["totalTestCount"] == 4 and summary["passedTests"] == 4, summary
        print("4 gallery UI tests passed: real paging, pinch/pan, sharing, close, swipe-down close, video pages and failure/retry")
        print(result)
    finally:
        for identifier in ["app.notebank.gallery-ui", "app.notebank.gallery-ui.tests.xctrunner"]:
            subprocess.run(["xcrun", "simctl", "uninstall", device, identifier], check=False)
