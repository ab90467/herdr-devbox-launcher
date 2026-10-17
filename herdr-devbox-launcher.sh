#!/bin/zsh
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
DEVBOX="devbox-jov-ne"
SESSION="devbox"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_RED=$'\033[31m'

ok()   { echo "  ${C_GREEN}✓${C_RESET} $1" }
bad()  { echo "  ${C_RED}✗${C_RESET} $1" }
info() { echo "  ${C_DIM}·${C_RESET} $1" }
step() { echo "${C_CYAN}${C_BOLD}▸ $1${C_RESET}" }
fail_and_exit() {
  stty sane 2>/dev/null
  printf '\033[?1000l\033[?1003l\033[?25h' 2>/dev/null
  echo ""
  read -k 1 "?Press 'r' to retry, or any other key to close..."
  echo ""
  if [[ "$REPLY" == [rR] ]]; then
    continue
  fi
  exit 1
}

while true; do
clear
TITLE="  herdr → ${DEVBOX}  "
BORDER=${(l:${#TITLE}::─:)}
echo "${C_BOLD}${C_CYAN}┌${BORDER}┐${C_RESET}"
echo "${C_BOLD}${C_CYAN}│${TITLE}│${C_RESET}"
echo "${C_BOLD}${C_CYAN}└${BORDER}┘${C_RESET}"
echo ""

step "tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  bad "ikke installert — kjør: brew install tailscale"
  fail_and_exit
fi
ok "installert"

TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('BackendState',''))" 2>/dev/null)
if [[ "$TS_STATE" != "Running" ]]; then
  bad "ikke oppe (status: ${TS_STATE:-ukjent}) — kjør: tailscale up"
  echo ""
  echo "${C_DIM}--- tailscale status ---${C_RESET}"
  tailscale status 2>&1
  fail_and_exit
fi
ok "oppe og kjører"
echo ""

step "$DEVBOX"
PING_FILE=$(mktemp)
tailscale ping -c 1 "$DEVBOX" > "$PING_FILE" 2>&1 &
PING_PID=$!
( sleep 5; kill -TERM "$PING_PID" 2>/dev/null ) &
WATCHER_PID=$!
wait "$PING_PID" 2>/dev/null
kill "$WATCHER_PID" 2>/dev/null
PING_OK=0
grep -q "pong from" "$PING_FILE" && PING_OK=1
rm -f "$PING_FILE"

if (( PING_OK )); then
  ok "svarer"
  echo ""

  step "herdr"
  if ! command -v herdr >/dev/null 2>&1; then
    info "ikke installert, installerer via Homebrew..."
    if BREW_OUT=$(brew install herdr 2>&1); then
      ok "installert ($(herdr --version 2>&1 | awk '{print $2}'))"
    else
      bad "installasjon feilet"
      echo ""
      echo "${C_DIM}--- brew install herdr ---${C_RESET}"
      echo "$BREW_OUT"
      fail_and_exit
    fi
  else
    ok "installert ($(herdr --version 2>&1 | awk '{print $2}'))"
  fi

  BREW_CACHE="$HOME/.cache/herdr-devbox-launcher/last-brew-update"
  mkdir -p "$(dirname "$BREW_CACHE")"
  NOW=$(date +%s)
  LAST=$(cat "$BREW_CACHE" 2>/dev/null || echo 0)
  AGE=$(( NOW - LAST ))
  if (( AGE > 43200 )); then
    info "sjekker Homebrew-indeks..."
    brew update --quiet >/dev/null 2>&1
    echo "$NOW" > "$BREW_CACHE"
  else
    info "Homebrew-indeks sjekket for $(( AGE / 60 )) min siden, hopper over"
  fi
  if brew outdated herdr 2>/dev/null | grep -q herdr; then
    info "ny versjon tilgjengelig, oppgraderer..."
    if BREW_OUT=$(brew upgrade herdr 2>&1); then
      ok "oppgradert til $(herdr --version 2>&1 | awk '{print $2}')"
    else
      bad "oppgradering feilet"
      echo ""
      echo "${C_DIM}--- brew upgrade herdr ---${C_RESET}"
      echo "$BREW_OUT"
      fail_and_exit
    fi
  else
    ok "siste versjon ($(herdr --version 2>&1 | awk '{print $2}'))"
  fi
  echo ""

  step "Claude Tools"
  if pgrep -f "Claude Tools.app/Contents/MacOS/ClaudeTools" >/dev/null 2>&1; then
    ok "kjører (copy/read-write/chrome-broene er dens ansvar)"
  else
    info "starter Claude Tools..."
    open -g -a "Claude Tools"
    sleep 1
    if pgrep -f "Claude Tools.app/Contents/MacOS/ClaudeTools" >/dev/null 2>&1; then
      ok "startet"
    else
      bad "fikk ikke startet — åpne ~/Applications/Claude Tools.app manuelt"
    fi
  fi
  echo ""

  echo "${C_GREEN}${C_BOLD}→ Kobler til (sesjon: ${SESSION})...${C_RESET}"
  sleep 0.3
  herdr --remote "$DEVBOX" --session "$SESSION" --remote-keybindings server --handoff
  HERDR_STATUS=$?
  if (( HERDR_STATUS != 0 )); then
    echo ""
    bad "herdr avsluttet med feil (kode $HERDR_STATUS)"
    fail_and_exit
  fi
  exit 0
fi

bad "svarer ikke på ping (5s timeout)"
echo ""
echo "${C_DIM}--- tailscale status (debug) ---${C_RESET}"
tailscale status 2>&1
echo ""
echo "${C_DIM}--- $DEVBOX ---${C_RESET}"
tailscale status 2>&1 | grep "$DEVBOX"
fail_and_exit
done
