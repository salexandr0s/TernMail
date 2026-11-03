#!/usr/bin/env python3
"""Capture native Tern views with fictional mail, calendars, tasks, and assistant responses."""

import argparse
import json
import pathlib
import plistlib
import subprocess
import uuid


def run(command: list[str], log: pathlib.Path, root: pathlib.Path) -> None:
    with log.open("w") as output:
        result = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f"Capture stopped. See {log}")


def export_srgb(source: pathlib.Path, destination: pathlib.Path,
                log: pathlib.Path, root: pathlib.Path) -> None:
    # Convert colors as well as replacing the display profile, which can identify the monitor.
    run(["/usr/bin/sips", "--matchTo", "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
         str(source), "--out", str(destination)], log, root)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Use an existing, current Debug test build")
    parser.add_argument("--section", choices=("all", "workspace", "assistant"), default="all",
                        help="Capture all views, the mail/calendar workspace, or the assistant and Tasks")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    derived = root / "build" / "readme-demo"
    derived.mkdir(parents=True, exist_ok=True)
    destination = "platform=macOS,arch=" + subprocess.check_output(["uname", "-m"], text=True).strip()
    if not args.skip_build:
        print("Building the app and native capture test…", flush=True)
        run(["xcodebuild", "-project", "Tern.xcodeproj", "-scheme", "Tern", "-configuration", "Debug",
             "-derivedDataPath", str(derived), "-destination", destination, "build-for-testing"],
            derived / "build.log", root)

    products = derived / "Build" / "Products"
    configs = sorted(products.glob("Tern_macos*.xctestrun"), key=lambda path: path.stat().st_mtime)
    if not configs:
        raise SystemExit("No test build found. Run again without --skip-build.")
    config = plistlib.loads(configs[-1].read_bytes())
    target = config["TernTests"]
    target.setdefault("EnvironmentVariables", {})["TERN_README_SCREENSHOTS"] = "1"
    target["CommandLineArguments"] = ["--ui-audit", "--ui-audit-calendar"]
    target["InProcessParallelizationEnabled"] = False
    target["UserAttachmentLifetime"] = "keepAlways"
    prepared = products / "ReadmeScreenshots.xctestrun"
    prepared.write_bytes(plistlib.dumps(config))

    run_id = uuid.uuid4().hex[:12]
    result = derived / f"screenshots-{run_id}.xcresult"
    sections = {
        "workspace": ("captureWorkspace", {"mail-light", "mail-dark", "calendar"}),
        "assistant": ("captureAssistantAndTasks", {"assistant", "follow-up", "events", "tasks"}),
    }
    selected = list(sections.values()) if args.section == "all" else [sections[args.section]]
    expected = set().union(*(names for _, names in selected))
    identifiers = {f"ReadmeScreenshots/{test}()" for test, _ in selected}
    tests = [f"-only-testing:TernTests/ReadmeScreenshots/{test}()" for test, _ in selected]
    print("Capturing the synthetic workspace. Keep the Mac unlocked…", flush=True)
    run(["xcodebuild", "test-without-building", "-xctestrun", str(prepared),
         "-destination", destination, "-parallel-testing-enabled", "NO",
         *tests, "-resultBundlePath", str(result)],
        derived / f"capture-{run_id}.log", root)
    exported = derived / f"export-{run_id}"
    run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
         "--output-path", str(exported)], derived / f"export-{run_id}.log", root)

    images = {}
    for test in json.loads((exported / "manifest.json").read_text()):
        if test["testIdentifier"] not in identifiers:
            continue
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"].split("_", 1)[0]
            if name in expected and not attachment["isAssociatedWithFailure"]:
                images[name] = exported / attachment["exportedFileName"]
    if images.keys() != expected:
        raise SystemExit(f"Missing captures: {', '.join(sorted(expected - images.keys()))}. Inspect {result}")
    output = root / "docs" / "screenshots"
    output.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(images.items()):
        export_srgb(source, output / f"{name}.png", derived / f"color-{name}-{run_id}.log", root)
    print(f"Saved {', '.join(name + '.png' for name in sorted(images))} to docs/screenshots.")
    print(f"Review all {len(images)} images before committing them.")


if __name__ == "__main__":
    main()
