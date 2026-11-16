#!/usr/bin/env bash
# Supervises a stdio MCP server child: passes stdin/stdout through
# untouched (never pollute the JSON-RPC stream), captures the child's
# stderr to a daily log (chrome-devtools-mcp's own diagnostics are
# invisible today — Claude Code owns the stdio pipe and nothing persists
# it), and auto-respawns on exit with backoff. Stops after repeated fast
# failures instead of looping forever, so a genuinely broken config
# surfaces as a dead MCP server instead of a silent infinite loop.
#
# A background health-check loop also proactively kills a child whose
# browser connection has gone silently stale (no crash, just dead CDP) —
# verified live: Claude Code's MCP client tolerates a respawned child on
# the same stdio pipe without a manual /mcp reconnect.
set -uo pipefail

LOG_DIR="$HOME/.cache/chrome-mcp-supervisor"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%Y-%m-%d).log"
PIDFILE="$LOG_DIR/current-child.$$.pid"
KILLMARK="$LOG_DIR/health-killed.$$.mark"
CDP_URL="${CDP_URL:-http://127.0.0.1:9229/json/version}"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 2
fi

log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') [$$] $*" >> "$LOG"
}

# TERM/kill a process and its direct children, escalating to KILL if it
# doesn't go away — $! after `npx ... &` is npx's own PID, and nothing
# guarantees npx forwards TERM to the real node server it execs.
kill_tree() {
  local pid="$1"
  [[ -z "$pid" ]] && return
  kill -TERM "$pid" 2>/dev/null
  pkill -TERM -P "$pid" 2>/dev/null
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null
  pkill -KILL -P "$pid" 2>/dev/null
}

HEALTH_FAILS_NEEDED=6

# Shared across every concurrent supervisor instance (one per Claude Code
# session), not per-$$ like PIDFILE/KILLMARK: "<epoch> ok|fail", refreshed
# by whichever instance happens to hold the lock when its own cache entry
# goes stale.
HEALTH_SHARED_STATE="$LOG_DIR/health-state"
HEALTH_SHARED_LOCK="$LOG_DIR/health-check.lock"
HEALTH_CACHE_MAX_AGE=15

# Probes the CDP endpoint at most once per $HEALTH_CACHE_MAX_AGE seconds
# across ALL concurrent supervisors combined, instead of once per
# supervisor every 20-29s. With N sessions each polling independently,
# N itself becomes enough concurrent load against Chrome's single CDP
# HTTP handler to manufacture the very failures the check is looking
# for — reproduced 2026-11-09: ~19 concurrent instances logged a
# correlated failure burst across nearly all of them in the same ~90s
# window, same shape as the 2026-11-04 incident the jittered interval
# below was already added for. De-duplicating the probe itself (this
# function), not just spreading out when each instance asks, is the
# actual fix — jitter only spread the same total request volume out in
# time, it didn't reduce it.
shared_health_probe() {
  local now state_time state_status state_age result

  now=$(date +%s)
  if [[ -f "$HEALTH_SHARED_STATE" ]]; then
    read -r state_time state_status < "$HEALTH_SHARED_STATE" 2>/dev/null
    if [[ "${state_time:-}" =~ ^[0-9]+$ ]]; then
      state_age=$(( now - state_time ))
      if (( state_age >= 0 && state_age < HEALTH_CACHE_MAX_AGE )); then
        [[ "$state_status" == "ok" ]]
        return
      fi
    fi
  fi

  exec 9>"$HEALTH_SHARED_LOCK"
  flock 9

  # Another instance may have refreshed the cache while we waited for it.
  now=$(date +%s)
  if [[ -f "$HEALTH_SHARED_STATE" ]]; then
    read -r state_time state_status < "$HEALTH_SHARED_STATE" 2>/dev/null
    if [[ "${state_time:-}" =~ ^[0-9]+$ ]]; then
      state_age=$(( now - state_time ))
      if (( state_age >= 0 && state_age < HEALTH_CACHE_MAX_AGE )); then
        flock -u 9
        exec 9>&-
        [[ "$state_status" == "ok" ]]
        return
      fi
    fi
  fi

  if curl -s --max-time 8 "$CDP_URL" >/dev/null 2>&1; then
    result=ok
  else
    result=fail
  fi
  echo "$now $result" > "$HEALTH_SHARED_STATE"
  flock -u 9
  exec 9>&-
  [[ "$result" == "ok" ]]
}

health_check_loop() {
  local fails=0
  while true; do
    # Jittered interval (20-29s): with 20+ concurrent instances (one per
    # Claude Code session) all checking on a flat 20s cadence, 2026-11-04
    # logged 25k+ "health check failed" and 8.4k kills in one day — far
    # more than the handful of real Prisma/DERP-relay blips that day
    # could explain. The devbox->Mac path runs over a Tailscale DERP
    # relay (confirmed: `direct connection not established`), which has
    # brief, ordinary jitter that a tight 3s curl timeout and a 60s
    # (3x20s) failure window treat as "Chrome is dead" far too eagerly.
    # Each instance still decides on its OWN 20-29s cadence whether it
    # personally has 6 consecutive failures — only the network probe
    # itself (shared_health_probe) is de-duplicated across instances.
    sleep "$(( 20 + RANDOM % 10 ))"
    if shared_health_probe; then
      fails=0
      continue
    fi
    fails=$(( fails + 1 ))
    log "health check failed (${fails}/${HEALTH_FAILS_NEEDED})"
    if (( fails >= HEALTH_FAILS_NEEDED )); then
      if [[ -f "$PIDFILE" ]]; then
        child_pid=$(cat "$PIDFILE")
        log "health check: killing unresponsive child pid=$child_pid"
        touch "$KILLMARK"
        kill_tree "$child_pid"
      fi
      fails=0
    fi
  done
}

cleanup() {
  [[ -n "${health_pid:-}" ]] && kill "$health_pid" 2>/dev/null
  [[ -n "${child_pid:-}" ]] && kill_tree "$child_pid"
  rm -f "$PIDFILE" "$KILLMARK"
}
trap cleanup EXIT
# A bare SIGTERM/SIGHUP/SIGINT does not run the EXIT trap — only an
# explicit `exit` from inside a handler does. Claude Code stops this
# script with SIGTERM on every /mcp reconnect, server disable, or
# session exit, so without this the child and the health loop leak on
# every single one of those (reproduced: confirmed via code review).
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 130' INT

# Backgrounding a command in bash silently redirects its stdin to
# /dev/null (verified: a backgrounded `cat` never saw piped input) —
# fatal for a stdio MCP server, which needs Claude Code's real stdin.
# Duplicate the supervisor's own stdin to fd 3 once, then feed the child
# from fd 3 explicitly so backgrounding doesn't sever it.
exec 3<&0

# health_check_loop must not hold stdout open — an orphaned copy (e.g.
# if cleanup is ever bypassed) would otherwise mask EOF on stdout from
# Claude Code, which could then wait on a server that already died.
health_check_loop >/dev/null 2>>"$LOG" &
health_pid=$!

# Resolve any "@latest" argument once, for this supervisor's whole
# lifetime, instead of on every respawn: re-resolving mid-session can
# silently change the server's tool schema under Claude Code, and the
# registry round-trip adds startup latency on every respawn (which,
# combined with a slow/offline registry, can take long enough to look
# like a crash-loop instead of a slow start). A fresh "@latest" is still
# picked up the next time Claude Code starts a fresh supervisor.
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == *"@latest" ]]; then
    pkg="${args[$i]%@latest}"
    # Bounded: Claude Code gives the MCP server 30s to answer initialize, and
    # an unbounded `npm view` stalls that long on a registry ETIMEDOUT
    # (2026-11-13: "/mcp ... connection timed out after 30000ms", no log line).
    # If the registry doesn't answer in time, fall back to the version in npm's
    # cache and let the child run cache-first too, instead of hanging on it.
    resolved="$(timeout 8 npm view "$pkg" version --fetch-retries=0 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      resolved="$(timeout 8 npm view "$pkg" version --offline 2>/dev/null || true)"
      if [[ -n "$resolved" ]]; then
        log "registry slow/unreachable, using cached $pkg@$resolved"
        export npm_config_prefer_offline=true
      fi
    fi
    if [[ -n "$resolved" ]]; then
      args[$i]="${pkg}@${resolved}"
      log "pinned ${args[$i]} for this supervisor's lifetime"
    fi
  fi
done
set -- "${args[@]}"

log "supervisor starting: $*"

delay=2
fast_failures=0

while true; do
  rm -f "$KILLMARK"
  start=$SECONDS
  "$@" <&3 2>> "$LOG" &
  child_pid=$!
  echo "$child_pid" > "$PIDFILE"
  wait "$child_pid"
  status=$?
  up=$(( SECONDS - start ))
  log "child exited status=$status uptime=${up}s"

  # status 0 with no health-check kill marker means the child shut down
  # cleanly on its own — almost always because its stdin (our fd 3, tied
  # to Claude Code's own pipe to this script) hit EOF, i.e. the client
  # went away. Respawning in that case just launches ~5 ghost servers
  # nobody will ever talk to (worse: forever, if a slow/offline npx
  # registry check makes each one's uptime >=10s, which also defeats the
  # fast-failure cap below). Exit instead; there is nothing left to serve.
  if [[ ! -f "$KILLMARK" && "$status" -eq 0 ]]; then
    log "child exited cleanly and was not health-killed — treating as client EOF, not respawning"
    exit 0
  fi

  if (( up < 10 )); then
    fast_failures=$(( fast_failures + 1 ))
  else
    fast_failures=0
    delay=2
  fi

  if (( fast_failures >= 5 )); then
    log "giving up after $fast_failures fast failures"
    exit 1
  fi

  log "respawning in ${delay}s"
  sleep "$delay"
  delay=$(( delay * 2 ))
  (( delay > 60 )) && delay=60
done
