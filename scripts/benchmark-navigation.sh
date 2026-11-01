#!/bin/bash
set -euo pipefail

# Builds a separate, optimized synthetic app. It never opens the user's stores.
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
event_count="${1:-100}"
case "$event_count" in 100|1000) ;; *) echo 'Usage: benchmark-navigation.sh [100|1000]' >&2; exit 2 ;; esac
build_root="${TERN_PERFORMANCE_BUILD_DIR:-/tmp/tern-performance-audit-build}"
report_dir="$HOME/Library/Containers/dev.tern.performance/Data/tmp"
report_path="$report_dir/tern-navigation-$event_count.json"
mkdir -p "$build_root"
mkdir -p "$report_dir"
run_dir="$build_root/reports/$(date -u '+%Y%m%dT%H%M%SZ')-$event_count"
mkdir -p "$run_dir"
git -C "$task_root" rev-parse HEAD > "$run_dir/revision.txt"
git -C "$task_root" diff --name-only > "$run_dir/uncommitted-paths.txt"
/usr/bin/sw_vers > "$run_dir/system.txt"

xcodebuild -project "$task_root/Tern.xcodeproj" -scheme Tern -configuration Release \
    -derivedDataPath "$build_root" \
    -clonedSourcePackagesDirPath "${TERN_SOURCE_PACKAGES_DIR:-$task_root/build/SourcePackages}" \
    -disableAutomaticPackageResolution \
    PRODUCT_BUNDLE_IDENTIFIER=dev.tern.performance \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TERN_PERFORMANCE' \
    ONLY_ACTIVE_ARCH=YES build > "$build_root/build.log" 2>&1

/usr/bin/python3 - "$report_path" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).unlink(missing_ok=True)
pathlib.Path(sys.argv[1] + '.progress.json').unlink(missing_ok=True)
PY
/usr/bin/python3 "$task_root/scripts/performance-process-memory.py" "$run_dir" \
    "$build_root/Build/Products/Release/Tern.app/Contents/MacOS/Tern" \
    --ui-audit --ui-audit-calendar --performance-audit --performance-exit --performance-memory-pause=12 \
    "--performance-events=$event_count" "--performance-output=$report_path"
cp "$report_path" "$run_dir/navigation.json"
echo "Report: $report_path"
echo "Archived report and process memory: $run_dir"
/usr/bin/python3 - "$report_path" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
errors = []
if report.get('error'): errors.append(report['error'])
if report.get('isOptimizedBuild') is not True: errors.append('Optimized build was not verified.')
expected = {'workspace-warm', 'attachments-return', 'reader-recent', 'reader-local'}
if expected - {s['name'] for s in report.get('scenarios', [])}: errors.append('Required navigation scenarios are missing.')
expected_scrolls = {'mailbox', 'reader-20', 'reader-100', 'calendar', 'attachments'}
if expected_scrolls - {s['name'] for s in report.get('scrolling', [])}: errors.append('Required scrolling scenarios are missing.')
for scenario in report.get('scenarios', []):
    if scenario['failures'] or scenario['completedInteractions'] < scenario['requestedInteractions']:
        errors.append(scenario['name'] + ': incomplete interactions')
for scroll in report.get('scrolling', []):
    if scroll.get('timedOut') or scroll.get('failureReason'): errors.append(scroll['name'] + ': incomplete scrolling')
for error in errors: print(error, file=sys.stderr)
sys.exit(bool(errors))
PY
