#!/bin/bash
# Native UI-only runner against the existing com.rinachan.board.mac app.
# No app build/launch, saved-state reset, system-dialog handling, or policy edits.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: tools/run_mac_drag_ui_tests.sh [--build-only]

Before running UI tests, leave the shipping Mac app open on Text with the
existing "Rina Drag Test" group selected, B (74801) before A (48E09).
Set RINA_MAC_GROUP_DRAG=1 to opt into real application UI input.
Set RINA_MAC_DRAG_REQUIRE_PAUSED_60=1 only after preparing paused 60-fps playback.
RINA_MAC_SIGN_IDENTITY selects an installed signing identity (default: -).
RINA_MAC_DRAG_WORKDIR optionally selects a parent for fresh runner artifacts.

If Automation Mode is disabled, run Product > Test in foreground Xcode and
complete its normal authentication prompt manually, then rerun this script.
The runner may separately need manually granted Accessibility permission.
--build-only builds the isolated runner without sending UI input.
USAGE
}

build_only=0
case "${1:-}" in
    --build-only) build_only=1 ;;
    --help|-h) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 64 ;;
esac
if [[ $# -gt 1 ]]; then usage >&2; exit 64; fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source_project="$repo_root/ios/RinaBoard.xcodeproj/project.pbxproj"
source_test="$repo_root/ios/RinaBoardUITests/GroupDragHardwareUITests.swift"
source_scheme="$repo_root/ios/RinaBoard.xcodeproj/xcshareddata/xcschemes/MacDragUITests.xcscheme"
sign_identity="${RINA_MAC_SIGN_IDENTITY:--}"
paused60="${RINA_MAC_DRAG_REQUIRE_PAUSED_60:-0}"

if [[ "$build_only" == 0 ]]; then
    if [[ "${RINA_MAC_GROUP_DRAG:-0}" != 1 ]]; then
        echo 'UI input is opt-in. Prepare the existing test group, then set RINA_MAC_GROUP_DRAG=1.' >&2
        exit 64
    fi
    if [[ ! -x /usr/bin/automationmodetool ]]; then
        echo 'Cannot inspect Automation Mode on this host. Use normal foreground Xcode Product > Test and authenticate manually.' >&2
        exit 69
    fi
    # No arguments is the documented read-only status operation. In particular,
    # never invoke either authentication-exemption mutator.
    mode_status="$(/usr/bin/automationmodetool 2>&1)" || {
        echo "$mode_status" >&2
        echo 'Could not inspect Automation Mode. Complete normal Xcode authentication manually.' >&2
        exit 77
    }
    echo "$mode_status"
    # Xcode enables Automation Mode for the run and disables it afterwards.
    # A disabled idle state is not evidence that normal authenticated testing
    # is unavailable; let Xcode perform its standard authentication flow.

fi

if [[ -n "${RINA_MAC_DRAG_WORKDIR:-}" ]]; then
    mkdir -p -- "$RINA_MAC_DRAG_WORKDIR"
    work_dir="$(mktemp -d "$RINA_MAC_DRAG_WORKDIR/run.XXXXXX")"
else
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/rina-mac-drag.XXXXXX")"
fi
project_dir="$work_dir/NativeDrag.xcodeproj"
mkdir -p -- "$project_dir/xcshareddata/xcschemes" "$work_dir/RinaBoardUITests"
cp -- "$source_test" "$work_dir/RinaBoardUITests/GroupDragHardwareUITests.swift"
/usr/bin/plutil -convert json -o "$work_dir/source-project.json" "$source_project"

python3 - "$work_dir/source-project.json" "$project_dir/project.pbxproj" "$source_scheme" \
    "$project_dir/xcshareddata/xcschemes/MacDragUITests.xcscheme" "$sign_identity" "$paused60" <<'PY'
import json
import plistlib
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

source, destination, scheme_source, scheme_destination, identity, paused60 = sys.argv[1:]
project = json.loads(Path(source).read_text())
objects = project['objects']
ui_target_id = 'A20000000000000000000003'
root = objects[project['rootObject']]
root['targets'] = [ui_target_id]
root['packageReferences'] = []
# Unreferenced original objects are intentionally retained; repository files
# are untouched and no application/package targets participate in this build.
attributes = root.get('attributes', {}).get('TargetAttributes', {})
for value in attributes.values():
    value.pop('TestTargetID', None)
target = objects[ui_target_id]
target['dependencies'] = []
target['packageProductDependencies'] = []
config_list = objects[target['buildConfigurationList']]
for config_id in config_list['buildConfigurations']:
    settings = objects[config_id]['buildSettings']
    settings.update({
        'SDKROOT': 'macosx',
        'SUPPORTED_PLATFORMS': 'macosx',
        'SUPPORTS_MACCATALYST': 'NO',
        'MACOSX_DEPLOYMENT_TARGET': '14.0',
        'TARGETED_DEVICE_FAMILY': '',
        'TEST_TARGET_NAME': '',
        'CODE_SIGN_STYLE': 'Manual',
        'CODE_SIGN_IDENTITY': identity,
        'DEVELOPMENT_TEAM': '',
    })
Path(destination).write_bytes(plistlib.dumps(project, fmt=plistlib.FMT_XML, sort_keys=False))

scheme = ET.parse(scheme_source)
scheme_root = scheme.getroot()
entries = scheme_root.find('./BuildAction/BuildActionEntries')
for entry in list(entries):
    reference = entry.find('BuildableReference')
    if reference is None or reference.get('BlueprintIdentifier') != ui_target_id:
        entries.remove(entry)
# This scheme drives an external running app through XCUIApplication(bundleID).
# Remove stale app-run references so it cannot accidentally launch/build the app.
for action_name in ('LaunchAction', 'ProfileAction'):
    action = scheme_root.find(action_name)
    if action is not None:
        for runnable in list(action.findall('BuildableProductRunnable')):
            action.remove(runnable)
for reference in scheme_root.iter('BuildableReference'):
    reference.set('ReferencedContainer', 'container:NativeDrag.xcodeproj')
test_action = scheme_root.find('TestAction')
test_action.set('shouldUseLaunchSchemeArgsEnv', 'NO')
old_environment = test_action.find('EnvironmentVariables')
if old_environment is not None:
    test_action.remove(old_environment)
environment = ET.SubElement(test_action, 'EnvironmentVariables')
for key, value in (
    ('RINA_GROUP_DRAG_HARDWARE', '1'),
    ('RINA_GROUP_DRAG_GROUP_SELECTED', 'Rina Drag Test'),
    ('RINA_GROUP_DRAG_REQUIRE_PAUSED_60', paused60),
):
    ET.SubElement(environment, 'EnvironmentVariable', key=key, value=value, isEnabled='YES')
scheme.write(scheme_destination, encoding='UTF-8', xml_declaration=True)
PY

project_args=(
    -project "$project_dir"
    -scheme MacDragUITests
    -destination 'platform=macOS'
    -derivedDataPath "$work_dir/DerivedData"
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$sign_identity"
    DEVELOPMENT_TEAM=
)
echo "Isolated runner and logs: $work_dir"
if ! /usr/bin/xcodebuild "${project_args[@]}" build-for-testing > "$work_dir/build.log" 2>&1; then
    tail -n 80 "$work_dir/build.log" >&2
    echo "Runner build failed; full log: $work_dir/build.log" >&2
    exit 1
fi
echo "Runner build succeeded: $work_dir/build.log"
if [[ "$build_only" == 1 ]]; then
    echo 'Build-only complete; no application UI input was sent.'
    exit 0
fi

# Prefixes propagate settings to XCTest's runner; scheme values above also make
# opening this isolated project in Xcode reproduce the same explicit test scope.
if ! env TEST_RUNNER_RINA_GROUP_DRAG_HARDWARE=1 \
    'TEST_RUNNER_RINA_GROUP_DRAG_GROUP_SELECTED=Rina Drag Test' \
    "TEST_RUNNER_RINA_GROUP_DRAG_REQUIRE_PAUSED_60=$paused60" \
    /usr/bin/xcodebuild "${project_args[@]}" test-without-building \
    -only-testing:RinaBoardUITests/GroupDragHardwareUITests \
    -resultBundlePath "$work_dir/DragUITests.xcresult" > "$work_dir/test.log" 2>&1; then
    tail -n 100 "$work_dir/test.log" >&2
    echo "UI test failed or was blocked; inspect: $work_dir/test.log" >&2
    echo 'If authentication or Accessibility is required, complete normal system authorization manually. This script changes no authorization policy.' >&2
    exit 1
fi
echo "UI test command finished. Inspect test/skip status and evidence: $work_dir/DragUITests.xcresult"
echo "Full runner log: $work_dir/test.log"
