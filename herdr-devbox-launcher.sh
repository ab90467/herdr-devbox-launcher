#!/bin/zsh
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
# Dock-launched Ghostty may have no UTF-8 locale; ${#str} below must count chars, not bytes.
export LC_CTYPE=en_US.UTF-8
DEVBOX="devbox-jov-ne"
SESSION="devbox"

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_RED=$'\033[31m'

# Warm purple→red→orange gradient, one stop per letter.
C_S=$'\033[38;2;139;29;130m'
C_O=$'\033[38;2;170;20;95m'
C_P=$'\033[38;2;207;2;43m'
C_R=$'\033[38;2;225;60;20m'
C_A=$'\033[38;2;240;125;0m'

# All status output goes into a framed box, centered on screen. Lines are
# collected in LN_STYLE/LN_TEXT and the whole screen is redrawn on each change;
# when there are more lines than fit, the oldest scroll out of the box.
LN_STYLE=()
LN_TEXT=()
LAST_SIZE=""

render() {
  local size rows cols width inner_h total top left art_left buf="" sp fill
  local k idx n start style text pre pv avail lead

  size=$(stty size 2>/dev/null)
  rows=${size% *}; cols=${size#* }
  [[ "$rows" == <-> && "$cols" == <-> ]] || { rows=24; cols=80 }

  width=$(( cols - 4 ));       (( width > 70 )) && width=70;       (( width < 30 )) && width=30
  inner_h=$(( rows - 10 ));    (( inner_h > 18 )) && inner_h=18;   (( inner_h < 6 )) && inner_h=6
  total=$(( 7 + inner_h + 2 ))  # blank + 5 logo rows + blank + box
  top=$(( (rows - total) / 2 + 1 ));  (( top < 1 )) && top=1
  left=$(( (cols - width) / 2 + 1 )); (( left < 1 )) && left=1
  # art is 5 letters * 5 cols + 4 separating spaces = 29 chars wide.
  art_left=$(( (cols - 29) / 2 + 1 )); (( art_left < 1 )) && art_left=1

  if [[ "$rows x $cols" != "$LAST_SIZE" ]]; then
    buf+=$'\033[2J'
    LAST_SIZE="$rows x $cols"
  fi

  local -a art=(
    "${C_S} ████${C_RESET} ${C_O} ███ ${C_RESET} ${C_P}████ ${C_RESET} ${C_R}████ ${C_RESET} ${C_A} ███ ${C_RESET}"
    "${C_S}█    ${C_RESET} ${C_O}█   █${C_RESET} ${C_P}█   █${C_RESET} ${C_R}█   █${C_RESET} ${C_A}█   █${C_RESET}"
    "${C_S} ███ ${C_RESET} ${C_O}█   █${C_RESET} ${C_P}████ ${C_RESET} ${C_R}████ ${C_RESET} ${C_A}█████${C_RESET}"
    "${C_S}    █${C_RESET} ${C_O}█   █${C_RESET} ${C_P}█    ${C_RESET} ${C_R}█  █ ${C_RESET} ${C_A}█   █${C_RESET}"
    "${C_S}████ ${C_RESET} ${C_O} ███ ${C_RESET} ${C_P}█    ${C_RESET} ${C_R}█   █${C_RESET} ${C_A}█   █${C_RESET}"
  )
  for (( k = 1; k <= 5; k++ )); do
    printf -v sp '\033[%d;%dH' $(( top + k )) "$art_left"
    buf+="${sp}${art[k]}"
  done

  # top border with title
  local title="kobler til ${DEVBOX}"
  printf -v fill '%*s' $(( width - 5 - ${#title} )) ""
  printf -v sp '\033[%d;%dH' $(( top + 7 )) "$left"
  buf+="${sp}${C_O}╭─${C_RESET} ${C_BOLD}${title}${C_RESET} ${C_O}${fill// /─}╮${C_RESET}"

  # content rows
  n=${#LN_TEXT}
  start=$(( n > inner_h ? n - inner_h + 1 : 1 ))
  for (( k = 0; k < inner_h; k++ )); do
    idx=$(( start + k ))
    text=""; pre=""; pv=0
    if (( idx <= n )); then
      style=${LN_STYLE[idx]}; text=${LN_TEXT[idx]}
      case "$style" in
        step) pre="${C_CYAN}${C_BOLD}▸ ";            pv=2 ;;
        ok)   pre="  ${C_GREEN}✓${C_RESET} ";         pv=4 ;;
        bad)  pre="  ${C_RED}✗${C_RESET} ";           pv=4 ;;
        info) pre="  ${C_DIM}·${C_RESET} ";           pv=4 ;;
        raw)  pre="  ${C_DIM}";                      pv=2 ;;
        go)   pre="${C_GREEN}${C_BOLD}→ ";           pv=2 ;;
        ask)  pre="${C_BOLD}${C_A}» ";               pv=2 ;;
      esac
      if [[ "$style" == ask ]]; then  # centered, so it stands out from the status lines
        lead=$(( (width - 4 - pv - ${#text}) / 2 )); (( lead < 0 )) && lead=0
        printf -v sp '%*s' "$lead" ""
        pre="${sp}${pre}"; pv=$(( pv + lead ))
      fi
    fi
    avail=$(( width - 4 - pv ))
    (( ${#text} > avail )) && text="${text[1,avail-1]}…"
    printf -v fill '%*s' $(( avail - ${#text} )) ""
    printf -v sp '\033[%d;%dH' $(( top + 8 + k )) "$left"
    buf+="${sp}${C_O}│${C_RESET} ${pre}${text}${C_RESET}${fill} ${C_O}│${C_RESET}"
  done

  # bottom border
  printf -v fill '%*s' $(( width - 2 )) ""
  printf -v sp '\033[%d;%dH' $(( top + 8 + inner_h )) "$left"
  buf+="${sp}${C_O}╰${fill// /─}╯${C_RESET}"

  printf '%s' "$buf"
}

add_line() { LN_STYLE+=("$1"); LN_TEXT+=("$2") }
ok()   { add_line ok "$1";   render }
bad()  { add_line bad "$1";  render }
info() { add_line info "$1"; render }
step() { add_line step "$1"; render }
go()   { add_line go "$1";   render }
# dump <title> <text> [max-lines]: command output as dim lines (last N lines).
dump() {
  local l
  add_line raw "--- $1 ---"
  while IFS= read -r l; do
    add_line raw "${l//$'\t'/ }"
  done <<< "$(print -r -- "$2" | tail -n "${3:-6}")"
  render
}

fail_and_exit() {
  stty sane 2>/dev/null
  printf '\033[?1000l\033[?1003l' 2>/dev/null
  add_line "" ""
  add_line ask "Press 'r' to retry, or any other key to close..."
  add_line "" ""
  render
  read -k 1 -s
  printf '\033[?25h'
  if [[ "$REPLY" == [rR] ]]; then
    continue
  fi
  exit 1
}

while true; do
LN_STYLE=(); LN_TEXT=(); LAST_SIZE=""
printf '\033[?25l'
clear
render

step "tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  bad "ikke installert — kjør: brew install tailscale"
  fail_and_exit
fi
ok "installert"

TS_STATE=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('BackendState',''))" 2>/dev/null)
if [[ "$TS_STATE" != "Running" ]]; then
  bad "ikke oppe (status: ${TS_STATE:-ukjent}) — kjør: tailscale up"
  dump "tailscale status" "$(tailscale status 2>&1)" 6
  fail_and_exit
fi
ok "oppe og kjører"

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

  step "herdr"
  if ! command -v herdr >/dev/null 2>&1; then
    info "ikke installert, installerer via Homebrew..."
    if BREW_OUT=$(brew install herdr 2>&1); then
      ok "installert ($(herdr --version 2>&1 | awk '{print $2}'))"
    else
      bad "installasjon feilet"
      dump "brew install herdr" "$BREW_OUT" 6
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
      dump "brew upgrade herdr" "$BREW_OUT" 6
      fail_and_exit
    fi
  else
    ok "siste versjon ($(herdr --version 2>&1 | awk '{print $2}'))"
  fi

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

  step "dev-prosesser"
  DEV_PROC_OUT=$(ssh -o ConnectTimeout=5 "$DEVBOX" python3 - < "$HOME/.local/bin/herdr-restart-stale-dev.py" 2>&1)
  if [[ -z "$DEV_PROC_OUT" ]]; then
    bad "fikk ikke sjekket (ingen svar fra devbox)"
  else
    while IFS='|' read -r kind label detail; do
      case "$kind" in
        RESTARTED) ok "$label restartet (var $detail)" ;;
        FRESH)     info "$label kjører fortsatt ($detail), rører den ikke" ;;
        MISSING)   info "$label: $detail" ;;
        ERROR)     bad "$label: $detail" ;;
        *)         info "$kind $label $detail" ;;
      esac
    done <<< "$DEV_PROC_OUT"
  fi

  # Hold Macen våken (idle-søvn) mens dette vinduet er åpent, maks 24 t: Chrome-
  # broen og SSH-tunnelene dør når Macen sover. -w følger denne prosessen, så
  # sperren forsvinner av seg selv når launcheren avslutter; -t er et tak så
  # Macen ikke holdes våken i dagevis av et glemt vindu. Lokk lukket sover den
  # uansett. CAFFEINATE_PID hindrer at retry-løkken starter flere.
  step "mac-søvn"
  if [[ -z "${CAFFEINATE_PID:-}" ]]; then
    caffeinate -i -t 86400 -w $$ &!
    CAFFEINATE_PID=$!
  fi
  ok "Mac holdes våken i opptil 24 t mens dette vinduet er åpent"

  go "Kobler til (sesjon: ${SESSION})..."
  sleep 0.3
  printf '\033[?25h'
  herdr --remote "$DEVBOX" --session "$SESSION" --remote-keybindings server --handoff
  HERDR_STATUS=$?
  if (( HERDR_STATUS != 0 )); then
    printf '\033[?25l'
    LAST_SIZE=""
    bad "herdr avsluttet med feil (kode $HERDR_STATUS)"
    fail_and_exit
  fi
  exit 0
fi

bad "svarer ikke på ping (5s timeout)"
dump "$DEVBOX" "$(tailscale status 2>&1 | grep "$DEVBOX" || echo 'ikke i tailscale status')" 2
fail_and_exit
done
