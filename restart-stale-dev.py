#!/usr/bin/env python3
# Runs ON the devbox (piped into `python3 -` over ssh by herdr-devbox-launcher.sh).
# Restarts npm start / dev-remote.sh in their existing herdr panes if they've
# been running longer than THRESHOLD_SECONDS, so stale kubectl port-forwards
# and a long-lived vite dev server get refreshed on launcher startup instead
# of silently rotting. Panes are found by cwd, not hardcoded pane IDs, since
# those aren't stable across herdr restarts.
#
# Prints one "KIND|label|detail" line per target; the caller renders it.
import json
import subprocess
import time

THRESHOLD_SECONDS = 6 * 3600

TARGETS = [
    ("npm start", "/home/jov/irma/aam/frontend", "npm start", "npm start"),
    ("dev-remote.sh", "/home/jov/irma/aam/scripts", "dev-remote.sh", "./dev-remote.sh"),
]


class HerdrError(Exception):
    pass


def herdr(*args):
    # ssh to the devbox can drop mid-call (the same network blips this
    # whole launcher already retries around) and return nothing, which
    # would otherwise surface as a raw JSONDecodeError traceback instead
    # of a line the caller's KIND|label|detail parser understands.
    #
    # Some subcommands (e.g. pane send-keys) print nothing at all on
    # success, so empty stdout only means failure when the exit code
    # also says so — otherwise treat it as a valid "no data" result.
    try:
        result = subprocess.run(
            ["herdr", "--session", "devbox", *args],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        raise HerdrError(f"tidsavbrudd: herdr {' '.join(args)}")
    out = result.stdout.strip()
    if not out:
        if result.returncode == 0:
            return None
        detail = result.stderr.strip()[:200]
        raise HerdrError(
            f"herdr {' '.join(args)} feila (kode {result.returncode})"
            + (f": {detail}" if detail else "")
        )
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        raise HerdrError(f"ugyldig svar fra herdr {' '.join(args)}: {out[:200]!r}")
    if isinstance(parsed, dict) and "error" in parsed:
        err = parsed["error"]
        raise HerdrError(f"herdr {' '.join(args)}: {err.get('message', err) if isinstance(err, dict) else err}")
    return parsed


def elapsed_seconds(pid):
    etime = subprocess.run(
        ["ps", "-o", "etime=", "-p", str(pid)],
        capture_output=True, text=True,
    ).stdout.strip()
    if not etime:
        return None, etime
    days = 0
    rest = etime
    if "-" in rest:
        days_str, rest = rest.split("-", 1)
        days = int(days_str)
    parts = [int(x) for x in rest.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    hours, minutes, seconds = parts
    return days * 86400 + hours * 3600 + minutes * 60 + seconds, etime


def main():
    try:
        panes = herdr("pane", "list")["result"]["panes"]
    except HerdrError as e:
        print(f"ERROR|dev-prosesser|{e}")
        return

    for label, cwd, match, restart_cmd in TARGETS:
        try:
            pane = next((p for p in panes if p.get("cwd") == cwd), None)
            if pane is None:
                print(f"MISSING|{label}|ingen pane med cwd {cwd}")
                continue
            pane_id = pane["pane_id"]
            info = herdr("pane", "process-info", "--pane", pane_id)
            procs = info["result"]["process_info"]["foreground_processes"]
            proc = next((p for p in procs if match in p["cmdline"]), None)
            if proc is None:
                print(f"MISSING|{label}|kjorer ikke i pane {pane_id}")
                continue
            secs, etime = elapsed_seconds(proc["pid"])
            if secs is None:
                print(f"MISSING|{label}|fant ikke prosess {proc['pid']}")
                continue
            if secs < THRESHOLD_SECONDS:
                print(f"FRESH|{label}|{etime}")
                continue
            herdr("pane", "send-keys", pane_id, "C-c")
            time.sleep(1)
            herdr("pane", "run", pane_id, restart_cmd)
            print(f"RESTARTED|{label}|var {etime}")
        except HerdrError as e:
            print(f"ERROR|{label}|{e}")


if __name__ == "__main__":
    main()
