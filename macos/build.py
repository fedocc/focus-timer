#!/usr/bin/env python3
"""Build with Apple's compiler. No third-party runtime or network dependencies."""
from pathlib import Path
import os
import plistlib
import struct
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
APP = BUILD / "Фокус.app"
SOURCES = sorted((ROOT / "Sources").glob("*.swift"))


def run(args):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT)


def main():
    BUILD.mkdir(exist_ok=True)
    cache = BUILD / "module-cache"
    cache.mkdir(exist_ok=True)
    architecture = os.uname().machine
    compiler = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", cache,
                "-target", architecture + "-apple-macosx14.0"]
    if "--test" in sys.argv:
        executable = BUILD / "FocusCoreTests"
        run([*compiler, ROOT / "Sources/FocusCore.swift", ROOT / "Tests/CoreTests.swift", "-o", executable])
        run([executable])
        discovery = BUILD / "DiscoveryTests"
        run([*compiler, ROOT / "Sources/FocusCore.swift", ROOT / "Sources/ApplicationService.swift",
             ROOT / "Tests/DiscoveryTests.swift", "-framework", "AppKit", "-o", discovery])
        run([discovery])
        return
    if "--ui-test" in sys.argv:
        executable = BUILD / "UISmoke"
        run([*compiler, "-D", "FOCUS_UI_TEST", *SOURCES, ROOT / "Tests/UISmoke.swift",
             "-framework", "AppKit", "-framework", "SwiftUI", "-o", executable])
        run([executable, BUILD / "ui-applications-check"])
        return
    if "--integration-test" in sys.argv:
        executable = BUILD / "AppIntegration"
        run([*compiler, ROOT / "Sources/FocusCore.swift", ROOT / "Sources/ApplicationService.swift",
             ROOT / "Tests/AppIntegration.swift", "-framework", "AppKit", "-framework", "ApplicationServices", "-o", executable])
        fixtures = BUILD / "app-integration"
        for role in ("a", "b"):
            fixture = fixtures / ("Fixture" + role.upper() + ".app")
            (fixture / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
            shutil.copy2(executable, fixture / "Contents/MacOS/Fixture")
            (fixture / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "local.fedor.focus-fixture." + role,
                "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
                "CFBundleName": "Focus fixture " + role, "LSMinimumSystemVersion": "14.0",
            }))
            run(["/usr/bin/codesign", "--force", "--sign", "-", fixture])
        run([executable, fixtures])
        return
    contents = APP / "Contents"
    binary = contents / "MacOS/FocusMenu"
    binary.parent.mkdir(parents=True, exist_ok=True)
    (contents / "Resources").mkdir(exist_ok=True)
    icon_tool = BUILD / "MakeIcon"
    run([*compiler, ROOT / "Tools/MakeIcon.swift", "-framework", "AppKit", "-o", icon_tool])
    iconset = BUILD / "Focus.iconset"
    run([icon_tool, iconset])
    # Modern ICNS stores PNG representations in length-prefixed chunks.
    chunks = []
    for tag, filename in [(b"icp4", "icon_16x16.png"), (b"icp5", "icon_32x32.png"),
                          (b"icp6", "icon_32x32@2x.png"), (b"ic07", "icon_128x128.png"),
                          (b"ic08", "icon_256x256.png"), (b"ic09", "icon_512x512.png"),
                          (b"ic10", "icon_512x512@2x.png")]:
        png = (iconset / filename).read_bytes()
        chunks.append(tag + struct.pack(">I", len(png) + 8) + png)
    body = b"".join(chunks)
    (contents / "Resources/Focus.icns").write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.fedor.focus-menu",
        "CFBundleName": "Фокус",
        "CFBundleDisplayName": "Фокус",
        "CFBundleExecutable": "FocusMenu",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.3",
        "CFBundleVersion": "4",
        "CFBundleIconFile": "Focus",
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }, sort_keys=True))
    run([*compiler, "-O", "-whole-module-optimization", *SOURCES,
         "-framework", "AppKit", "-framework", "SwiftUI", "-o", binary])
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "local.fedor.focus-menu", APP])
    run(["/usr/bin/codesign", "--verify", "--strict", APP])
    print(APP)


if __name__ == "__main__":
    main()
