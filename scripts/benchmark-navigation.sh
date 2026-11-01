#!/bin/bash
set -euo pipefail

# Builds a separate, optimized synthetic app. It never opens the user's stores.
task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
event_count="${1:-100}"
scenario="${2:-all}"
variant="${3:-normal}"
case "$event_count" in 100|1000) ;; *) echo 'Usage: benchmark-navigation.sh [100|1000] [all|workspace-only]' >&2; exit 2 ;; esac
case "$scenario" in all|workspace-only) ;; *) echo 'Scenario must be all or workspace-only.' >&2; exit 2 ;; esac
case "$variant" in normal|fixed-key-loop) ;; *) echo 'Variant must be normal or fixed-key-loop.' >&2; exit 2 ;; esac
build_root="${TERN_PERFORMANCE_BUILD_DIR:-/tmp/tern-performance-audit-build}"
report_dir="$HOME/Library/Containers/dev.tern.performance/Data/tmp"
report_path="$report_dir/tern-navigation-$event_count-$scenario-$variant.json"
mkdir -p "$build_root"
mkdir -p "$report_dir"
run_dir="$build_root/reports/$(date -u '+%Y%m%dT%H%M%SZ')-$event_count-$scenario-$variant"
mkdir -p "$run_dir"
build_revision="$(git -C "$task_root" rev-parse HEAD)"
if [ -n "$(git -C "$task_root" status --porcelain)" ]; then build_revision="$build_revision-dirty"; fi
printf '%s\n' "$build_revision" > "$run_dir/current-worktree-revision.txt"
git -C "$task_root" status --short > "$run_dir/uncommitted-paths.txt"
/usr/bin/sw_vers > "$run_dir/system.txt"

if [ "${TERN_PERFORMANCE_REUSE_BUILD:-0}" = 1 ]; then
    test -x "$build_root/Build/Products/Release/Tern.app/Contents/MacOS/Tern"
    echo 'Reused an existing audit binary; current worktree revision is not asserted as its source revision.' > "$run_dir/build-mode.txt"
else
    echo 'Built from the recorded current worktree revision and modified paths.' > "$run_dir/build-mode.txt"
    xcodebuild -project "$task_root/Tern.xcodeproj" -scheme Tern -configuration Release \
    -derivedDataPath "$build_root" \
    -clonedSourcePackagesDirPath "${TERN_SOURCE_PACKAGES_DIR:-$task_root/build/SourcePackages}" \
    -disableAutomaticPackageResolution \
    PRODUCT_BUNDLE_IDENTIFIER=dev.tern.performance "TERN_BUILD_REVISION=$build_revision" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TERN_PERFORMANCE' \
    ONLY_ACTIVE_ARCH=YES build > "$build_root/build.log" 2>&1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$build_root/Build/Products/Release/Tern.app/Contents/Info.plist")" = dev.tern.performance
/usr/bin/shasum -a 256 "$build_root/Build/Products/Release/Tern.app/Contents/MacOS/Tern" > "$run_dir/executable-sha256.txt"

/usr/bin/python3 - "$report_path" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).unlink(missing_ok=True)
pathlib.Path(sys.argv[1] + '.progress.json').unlink(missing_ok=True)
pathlib.Path(sys.argv[1] + '.current.json').unlink(missing_ok=True)
PY
audit_variant_args=()
if [ "$variant" = fixed-key-loop ]; then audit_variant_args+=(--performance-fixed-key-loop); fi
/usr/bin/python3 "$task_root/scripts/performance-process-memory.py" "$run_dir" \
    "$build_root/Build/Products/Release/Tern.app/Contents/MacOS/Tern" \
    --ui-audit --ui-audit-calendar --performance-audit --performance-exit --performance-memory-pause=12 \
    "--performance-events=$event_count" "--performance-scenario=$scenario" "--performance-output=$report_path" "${audit_variant_args[@]}"
cp "$report_path" "$run_dir/navigation.json"
echo "Report: $report_path"
echo "Archived report and process memory: $run_dir"
/usr/bin/python3 "$task_root/scripts/validate-navigation-report.py" "$report_path"
