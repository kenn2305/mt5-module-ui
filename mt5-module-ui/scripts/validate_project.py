from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    "Makefile",
    "control",
    "MT5ModuleUI.plist",
    "Tweak.xm",
    "Sources/MUIRuntime.m",
    "Sources/MUIDesignerViewController.m",
    "Sources/MUIScreenEditorViewController.m",
    "Sources/MUIScreenOverlayManager.m",
    "Sources/MUIScreenLayoutStore.m",
    "layout/DEBIAN/postinst",
    "layout/DEBIAN/prerm",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


for relative in REQUIRED:
    if not (ROOT / relative).is_file():
        fail(f"missing required file: {relative}")

makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
for required in (
    "THEOS_PACKAGE_SCHEME = rootless",
    "ARCHS = arm64 arm64e",
    "TARGET = iphone:clang:latest:15.0",
):
    if required not in makefile:
        fail(f"Makefile is missing: {required}")

control = (ROOT / "control").read_text(encoding="utf-8")
fields = {}
for line in control.splitlines():
    if ":" in line:
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip()
for field in ("Package", "Name", "Version", "Architecture", "Depends"):
    if not fields.get(field):
        fail(f"control is missing field: {field}")
if fields["Architecture"] != "iphoneos-arm64":
    fail("rootless package architecture must be iphoneos-arm64")
if "firmware (>= 15.0)" not in fields["Depends"] or "firmware (<< 17.0)" not in fields["Depends"]:
    fail("control must restrict installation to iOS 15-16")

raw_filter = (ROOT / "MT5ModuleUI.plist").read_text(encoding="utf-8")
if "net.metaquotes.MetaTrader5Terminal" not in raw_filter:
    fail("injection filter does not target MT5 bundle ID")

runtime = (ROOT / "Sources/MUIRuntime.m").read_text(encoding="utf-8")
if "restoreBaselineWithoutSaving" not in runtime:
    fail("runtime rollback path is missing")
if "setViewControllers" not in runtime:
    fail("runtime does not apply controller ordering")
if "0.15 * NSEC_PER_SEC" in runtime:
    fail("screen layout still contains a visible delayed-apply path")
if "refreshCurrentScreenLayout" not in runtime:
    fail("screen layout immediate refresh path is missing")
if "prepareContentViewController" not in runtime:
    fail("incoming controller pre-display layout path is missing")

designer = (ROOT / "Sources/MUIDesignerViewController.m").read_text(encoding="utf-8")
if "PHPickerViewController" not in designer:
    fail("Photos icon picker is missing")
if "moveRowAtIndexPath" not in designer:
    fail("drag reorder implementation is missing")

screen_editor = (ROOT / "Sources/MUIScreenEditorViewController.m").read_text(encoding="utf-8")
for feature in ("handlePanned", "handlePinched", "Choose from Photos", "linkTapped", "addCustomElement", "scaleSliderChanged", "canvasPanned", "maximumValue = 50.0", "imageRectForContentRect", "natural_w", "saveOriginalImage"):
    if feature not in screen_editor:
        fail(f"screen icon editor is missing feature: {feature}")

overlay_manager = (ROOT / "Sources/MUIScreenOverlayManager.m").read_text(encoding="utf-8")
for invariant in ("sendActionsForControlEvents", "removeOverlaysAndRestoreOriginals", "removeOverlayAndRestoreOriginalsForRootView", "scanCandidatesInRootView", "hostsByRoot", "presentActionPanelForElement"):
    if invariant not in overlay_manager:
        fail(f"screen overlay manager is missing invariant: {invariant}")

print("Project structure and safety invariants look valid.")
