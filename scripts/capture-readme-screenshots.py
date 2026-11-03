#!/usr/bin/env python3
"""Capture the native workspace with fictional mail, labels, and calendars."""

import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import uuid


def run(command: list[str], log: pathlib.Path, root: pathlib.Path) -> None:
    with log.open("w") as output:
        result = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f"Capture stopped. See {log}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Use an existing, current Debug test build")
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
    print("Capturing the synthetic workspace. Keep the Mac unlocked…", flush=True)
    run(["xcodebuild", "test-without-building", "-xctestrun", str(prepared),
         "-destination", destination, "-parallel-testing-enabled", "NO",
         "-only-testing:TernTests/ReadmeScreenshots", "-resultBundlePath", str(result)],
        derived / f"capture-{run_id}.log", root)
    exported = derived / f"export-{run_id}"
    run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
         "--output-path", str(exported)], derived / f"export-{run_id}.log", root)

    expected = {"mail-light", "mail-dark", "calendar"}
    images = {}
    for test in json.loads((exported / "manifest.json").read_text()):
        if test["testIdentifier"] != "ReadmeScreenshots/captureWorkspace()":
            continue
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"].split("_", 1)[0]
            if name in expected and not attachment["isAssociatedWithFailure"]:
                images[name] = exported / attachment["exportedFileName"]
    if images.keys() != expected:
        raise SystemExit(f"The capture did not produce all three images. Inspect {result}")
    output = root / "docs" / "screenshots"
    output.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(images.items()):
        shutil.copyfile(source, output / f"{name}.png")
    print("Saved mail-light.png, mail-dark.png, and calendar.png to docs/screenshots.")
    print("Review all three images before committing them.")


if __name__ == "__main__":
    main()
