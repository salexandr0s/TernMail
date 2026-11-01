#!/usr/bin/env python3
"""Run only the requested synthetic app; sample RSS without inspecting mail data.

XPC services commonly have launchd as their parent. Those WebKit services remain
unattributed unless a post-measurement sample identifies the responsible app PID;
creating a new PID during this run is not ownership proof.
"""
import datetime
import json
import pathlib
import re
import subprocess
import sys
import time

output = pathlib.Path(sys.argv[1])
command = sys.argv[2:]
executable_path = pathlib.Path(command[0]).resolve()
verified_owners = {}


def sample(phase, audit_pid=None):
    raw = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,rss=,comm="], text=True)
    processes = []
    for line in raw.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        pid, ppid, rss = map(int, fields[:3])
        processes.append(dict(pid=pid, parentPID=ppid, residentBytes=rss * 1024, executable=fields[3]))
    descendants = {audit_pid} if audit_pid is not None else set()
    while True:
        expanded = descendants | {p["pid"] for p in processes if p["parentPID"] in descendants}
        if expanded == descendants:
            break
        descendants = expanded
    selected = []
    for process in processes:
        executable = process["executable"]
        if process["pid"] == audit_pid or "WebKit" in executable or executable.endswith("/Tern"):
            process["attribution"] = ("audit-app" if process["pid"] == audit_pid else
                                      "audit-descendant" if process["pid"] in descendants else
                                      "audit-responsible-process" if audit_pid is not None and verified_owners.get(process["pid"]) == audit_pid else "unknown")
            selected.append(process)
    return dict(phase=phase, utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                auditPID=audit_pid, measurement="RSS from ps; not physical footprint",
                webKitAttribution="Only an observed parent chain or sample Responsible PID establishes ownership; other WebKit memory is unknown.",
                processes=selected)


def inspect_responsibility(snapshot, initial_pids, audit_pid):
    """Run only after final timing JSON exists; never sample during a timing scenario."""
    evidence = []
    for process in snapshot["processes"]:
        if "WebKit" not in process["executable"] or process["pid"] in initial_pids:
            continue
        pid = process["pid"]
        raw_path = output / ("webkit-%s.sample.tmp" % pid)
        try:
            result = subprocess.run(["/usr/bin/sample", str(pid), "1", "1", "-file", str(raw_path)],
                                    capture_output=True, text=True, timeout=5)
            raw = raw_path.read_text() if raw_path.exists() else ""
            header = "\n".join(raw.split("Call graph:", 1)[0].splitlines()[:35]) + "\n"
            (output / ("webkit-%s-process-header.txt" % pid)).write_text(header)
            responsible = re.search(r"^Responsible:.*\[(\d+)\]", header, re.MULTILINE)
            footprint = re.search(r"^Physical footprint:\s*(.+)$", header, re.MULTILINE)
            owner = int(responsible.group(1)) if responsible else None
            if owner is not None: verified_owners[pid] = owner
            evidence.append(dict(pid=pid, responsiblePID=owner, attributedToAudit=owner == audit_pid,
                                 residentBytes=process["residentBytes"],
                                 physicalFootprintRaw=footprint.group(1) if footprint else None,
                                 sampleExitCode=result.returncode))
        except (OSError, subprocess.TimeoutExpired):
            evidence.append(dict(pid=pid, attributedToAudit=False, error="Process-header attribution unavailable."))
        finally:
            raw_path.unlink(missing_ok=True)
    (output / "webkit-responsibility.json").write_text(json.dumps(evidence, indent=2))


with (output / "process-memory.jsonl").open("w") as samples, (output / "launch.log").open("w") as launch_log:
    def record(phase, pid=None):
        snapshot = sample(phase, pid)
        samples.write(json.dumps(snapshot) + "\n")
        samples.flush()
        return snapshot

    before = record("before")
    initial_pids = {p["pid"] for p in before["processes"]}
    if any(pathlib.Path(p["executable"]).resolve() == executable_path for p in before["processes"]):
        raise SystemExit("The isolated audit executable is already running; no second instance was opened.")
    bundle = pathlib.Path(command[0]).parents[2]
    app = subprocess.Popen(["/usr/bin/open", "-n", "-W", "-a", str(bundle),
                            "--stdout", str(output / "app.log"), "--stderr", str(output / "app.stderr.log"),
                            "--args"] + command[1:], stdout=launch_log, stderr=subprocess.STDOUT)
    audit_pid = None
    final_report = next((pathlib.Path(a.split("=", 1)[1]) for a in command if a.startswith("--performance-output=")), None)
    inspected = False
    while app.poll() is None:
        snapshot = record("running", audit_pid)
        if audit_pid is None:
            matches = [p["pid"] for p in snapshot["processes"] if pathlib.Path(p["executable"]).resolve() == executable_path]
            if len(matches) == 1: audit_pid = matches[0]
        if audit_pid is not None and final_report is not None and final_report.exists() and not inspected:
            inspected = True
            inspect_responsibility(snapshot, initial_pids, audit_pid)
        time.sleep(2)
    record("after", audit_pid)
    sys.exit(app.returncode)
