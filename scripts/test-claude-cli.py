#!/usr/bin/env python3
"""Run the Claude helper checks; --live also uses the signed-in CLI with synthetic data."""

import argparse
import pathlib
import plistlib
import subprocess
import uuid


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true", help="Use a current build-for-testing result")
    parser.add_argument("--live", action="store_true", help="Make synthetic requests using the current Claude subscription")
    parser.add_argument("--ui", action="store_true", help="Run the synthetic Settings UI check on an unlocked Mac")
    parser.add_argument("--standalone-live-ui", action="store_true", help="Test live Claude in the normal app sandbox, without hosted-test entitlements")
    args = parser.parse_args()
    if args.standalone_live_ui and (args.live or args.ui):
        parser.error("Use --standalone-live-ui separately from --live and --ui.")
    root = pathlib.Path(__file__).resolve().parent.parent
    derived = root / "build" / "claude-cli"
    logs = derived / "validation"
    logs.mkdir(parents=True, exist_ok=True)
    destination = "platform=macOS,arch=" + subprocess.check_output(["uname", "-m"], text=True).strip()

    def run(command: list[str], log: pathlib.Path) -> None:
        print(f"Running {command[0]} (log: {log})", flush=True)
        with log.open("w") as output:
            subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT, check=True)

    standalone_test = "TernUITests/AssistantProviderUITests/testStandaloneClaudeCLIConnectsAndRespondsToSyntheticPrompt"
    build = ["xcodebuild", "-project", "Tern.xcodeproj", "-scheme", "Tern", "-configuration", "Debug-Testing",
             "-derivedDataPath", str(derived), "-destination", destination]
    if not args.skip_build:
        run(["xcodegen", "generate"], logs / "generate.log")
        if args.standalone_live_ui:
            build += ["CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"]
            run(build + ["-only-testing:" + standalone_test, "build-for-testing"], logs / "build-live-ui.log")
            # build-for-testing adds sandbox exceptions even when base entitlement
            # injection is off. A normal build re-signs the app without them.
            run(build + ["build"], logs / "build-standalone.log")
        else:
            run(build + ["build-for-testing"], logs / "build.log")
    products = derived / "Build" / "Products"
    candidates = sorted(products.glob("Tern_macos*.xctestrun"), key=lambda path: path.stat().st_mtime)
    if not candidates:
        raise SystemExit("No test build found. Run again without --skip-build.")
    config = plistlib.loads(candidates[-1].read_bytes())
    if args.standalone_live_ui:
        config["TernUITests"].setdefault("EnvironmentVariables", {})["TERN_CLAUDE_LIVE_UI_TEST"] = "1"
    else:
        app_tests = config["TernTests"]
        app_tests["CommandLineArguments"] = ["--ui-audit", "--ui-audit-calendar"]
        app_tests["InProcessParallelizationEnabled"] = False
        app_tests.setdefault("EnvironmentVariables", {})["TERN_CLAUDE_LIVE_TEST"] = "1" if args.live else "0"
    prepared = products / "ClaudeCLIValidation.xctestrun"
    prepared.write_bytes(plistlib.dumps(config))
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(prepared), "-destination", destination,
               "-parallel-testing-enabled", "NO"]
    if args.standalone_live_ui:
        command += ["-only-testing:" + standalone_test]
    else:
        command += ["-only-testing:ClaudeHelperTests", "-only-testing:TernTests/ClaudeCLIConnectionTests",
                    "-only-testing:TernTests/AssistantProviderConnectionTests",
                    "-only-testing:TernTests/AssistantProviderIntegrationTests"]
    if args.live:
        command += ["-only-testing:TernTests/ClaudeCLILiveTests"]
    if args.ui:
        command += ["-only-testing:TernUITests/AssistantProviderUITests"]
    identifier = uuid.uuid4().hex[:10]
    command += ["-resultBundlePath", str(logs / f"checks-{identifier}.xcresult")]

    def verify_sandbox() -> None:
        signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(products / "Debug-Testing/Tern.app")],
                                capture_output=True, check=True)
        entitlements = plistlib.loads(signed.stdout)
        if (entitlements.get("com.apple.security.app-sandbox") is not True
                or any("temporary-exception" in key for key in entitlements)
                or entitlements.get("com.apple.security.get-task-allow")):
            raise SystemExit("Standalone verification requires the normal app sandbox, without test exceptions.")
        (logs / f"standalone-entitlements-{identifier}.plist").write_bytes(signed.stdout)

    if args.standalone_live_ui:
        verify_sandbox()
    run(command, logs / f"checks-{identifier}.log")
    if args.standalone_live_ui:
        verify_sandbox()
    print("Claude CLI checks passed.")


if __name__ == "__main__":
    main()
