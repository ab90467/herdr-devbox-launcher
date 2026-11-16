# devbox-chrome-bridge

Lar `chrome-devtools-mcp` på devboxen (`<devbox-host>`) styre Chrome på Mac-en.

## Arkitektur

```
Mac: Chrome :9222
  └─ SSH -R 9222:127.0.0.1:9222 ─────────────►  devbox 127.0.0.1:9222
                                                   └─ cdp-devtools-filter-proxy
                                                        HTTP :9229  /  WS :9228
                                                           └─ chrome-devtools-mcp --browser-url=http://127.0.0.1:9229
```

| Ledd | Hvor | Port | Hva |
|---|---|---|---|
| Chrome | Mac | 9222 | Startet med `--remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 --user-data-dir="$HOME/Library/Application Support/chrome-mcp"` |
| Reverse-tunnel | Mac → devbox | 9222 | `ssh -N -T -R 9222:127.0.0.1:9222 <user>@<devbox-host>` |
| Filter-proxy | devbox | 9229 (HTTP), 9228 (WS) | Se under |
| MCP-server | devbox | – | `--browser-url=http://127.0.0.1:9229` i `~/.claude.json`, startet via `chrome-mcp-supervisor.sh` |

**MCP-en skal peke på 9229, ikke 9222.** 9222 på devboxen er bare tunnelen rett til Chrome.

## Hvorfor en proxy

Når et ekte DevTools-vindu er festet til en fane, henger `Target.getTargets` over WebSocket i ca. 60 s, selv om HTTP `/json/list` svarer raskt. Proxyen:

- svarer på `Target.getTargets` fra HTTP-endepunktet i stedet for å sende det videre,
- filtrerer ut `devtools://`-mål fra lister og hendelser,
- **lukker klienten (WS-kode 1011) hvis forbindelsen til Chrome faller eller fane-ID-en er død**, i stedet for å koble til på nytt i det stille. En ny oppstrøms-WS er en helt ny CDP-forbindelse der klientens `sessionId`-er ikke finnes, og klienten får aldri beskjed. (Tidligere versjon reconnectet stille og ga akkurat det symptomet under.)
- bruker en **mild keepalive mot Chrome: ping hvert 20. s, gir opp etter 60 s** (biblioteket har 20 s som standard). Chrome på en travel Mac kan stoppe lenger enn 20 s uten å være død (2026-11-16: brudd med Mac-en våken, 1,4 GB-renderere og GPU på 35 %), og hvert brudd koster klienten hele sesjonen. Testet med et relé som ble frosset i 50 s: 20 s-versjonen lukket klienten (1011), 60 s-versjonen beholdt den og svarte etterpå. Et reelt avbrudd lukker fortsatt klienten, bare senere.

Detaljer står i kommentarene øverst i `devbox/bin/cdp-devtools-filter-proxy.py`.

## Installasjon på devboxen

```bash
# skript
mkdir -p ~/.local/bin ~/.local/share/cdp-proxy ~/.local/state/cdp-proxy ~/.config/systemd/user
cp devbox/bin/* ~/.local/bin/
chmod +x ~/.local/bin/chrome-mcp-supervisor.sh

# venv med websockets (versjon testet: 17.4)
python3 -m venv ~/.local/share/cdp-proxy/venv
~/.local/share/cdp-proxy/venv/bin/pip install websockets==17.4

# tjeneste
cp devbox/systemd-user/cdp-devtools-filter-proxy.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now cdp-devtools-filter-proxy.service

# valgfritt: start uten innlogging etter reboot
loginctl enable-linger <user>
```

Loggen ligger i `~/.local/state/cdp-proxy/proxy.log`.

## Sjekke status (bridgen er flere ledd – sjekk alle)

```bash
# 1) Mac: Chrome og tunnel
curl -s http://127.0.0.1:9222/json/version | head -3
ps -axo args= | grep -- '-R 9222'

# 2) devbox: tunnelen kommer frem, og proxyen lytter
ssh <user>@<devbox-host> 'curl -s -m5 http://127.0.0.1:9222/json/version | head -3; ss -ltn | grep -E ":(9222|9228|9229)\b"'

# 3) devbox: proxyen svarer, og tjenesten er oppe
ssh <user>@<devbox-host> 'curl -s -m5 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9229/json/version; systemctl --user is-active cdp-devtools-filter-proxy'
```

Å sjekke bare 9222 sier ingenting om MCP-en virker.

## Feilsøking

| Symptom | Sannsynlig årsak | Tiltak |
|---|---|---|
| `curl 127.0.0.1:9229` → connection refused | Proxyen kjører ikke (f.eks. etter reboot uten linger) | `systemctl --user start cdp-devtools-filter-proxy`; vurder `enable-linger` |
| 9222 virker, 9229 ikke | Samme som over – 9222 er bare tunnelen | Som over |
| `list_pages` virker, men `new_page` / `navigate_page` / skjermbilde henger, eller «Session closed» på en fane | Oppstrøms-WS til Chrome falt (typisk når **Mac-en gikk i dvale** og tunnelen frøs), og klienten satt igjen med døde CDP-sesjoner. `list_pages` virker fordi den svares fra HTTP. Proxyen lukker nå klienten (1011) ved brudd; hos en MCP-prosess som er startet før fiksen eller ikke tar opp en ny sesjon selv, gjelder fortsatt: | `/mcp` → reconnect i Claude Code-sesjonen, og kall `list_pages` på nytt for ferske fane-ID-er |
| `/mcp` → `Failed to reconnect to chrome-devtools: connection timed out after 30000ms`, og ingen ny linje («pinned» / «supervisor starting») i supervisor-loggen | `chrome-mcp-supervisor.sh` kjører `npm view <pkg> version` uten timeout før MCP-en starter. Ved nettverkshikke mot npm-registeret (2026-11-13: `GET registry.npmjs.org/chrome-devtools-mcp attempt 1 failed with ETIMEDOUT` i `~/.npm/_logs/`) går det over Claude Codes 30 s. Forsøket drepes uten opprydding og etterlater en løs helsesjekk-løkke (`ps`: supervisor med stdin/stdout `/dev/null`, ppid 1). *(Årsaken er utledet av loggen; MCP-en startet fint på 2 s da registeret var oppe igjen.)* | Fikset 2026-11-14: `npm view` har nå 8 s timeout og faller tilbake til npm-cachen (`--offline`, loggføres som `registry slow/unreachable, using cached …`). Testet med blackhole-proxy: `initialize` på 9,5 s. Den løse helsesjekk-løkken ved drept supervisor (SIGKILL) er ikke fikset. |
| Kall mot en fane gir feil umiddelbart | Fane-ID-en finnes ikke lenger (Chrome svarer HTTP 500 på WS-oppgraderingen). Proxyen lukker nå klienten med 1011 på ~0,1 s i stedet for å henge. | `list_pages` på nytt |
| Lesing virker, men fanen «endrer seg ikke» | Fanen er skjult (`document.visibilityState == "hidden"`); Chrome throttler skjulte faner | Hent fanen frem først (`select_page`) |
| `ssh … Address already in use` for 8000/3332/8080/13000 | `LocalForward` i `~/.ssh/config` kolliderer med herdr-sesjonen | Ufarlig; bruk `-o ClearAllForwardings=yes` ved enkeltkommandoer |

## Mac-dvale (verifisert årsak til brudd)

2026-11-13: proxy-loggen viste `ConnectionClosedError` kl. 21:38:40 CET, `keepalive ping timeout` og `upstream connect failed` hvert 11. s til 21:41:42. `pmset -g log` viste Idle Sleep 21:38:45 og Wake 21:41:17 (på batteri). Chrome og tunnelen var altså frosset mens Mac-en sov.

Forebygging: `caffeinate -i` på Mac-en mens du jobber mot devboxen, eller skru av dvale på batteri. Etter at Mac-en har sovet må en gammel MCP-sesjon kobles til på nytt (`/mcp`).

## Test av proxyens bruddoppførsel

Start en TCP-relé mellom proxyen og Chrome, koble en klient til proxyen, drep releet, og sjekk at klienten lukkes med 1011 (ikke henger):

```bash
CDP_UPSTREAM_PORT=9239 CDP_HTTP_PORT=9249 CDP_WS_PORT=9248 python cdp-devtools-filter-proxy.py   # relé: 9239 -> 9222
```

Kjørt 2026-11-13: klient lukket etter 0,01 s med `code=1011 reason='upstream dropped'`.

## Kjente svakheter

- Supervisor-helsesjekken er kun HTTP, ikke WS; den dreper aldri en MCP-prosess med død WS. Om `chrome-devtools-mcp` tar opp en ny sesjon av seg selv etter 1011 er ikke testet mot en ekte MCP-sesjon.
- Proxyen og MCP-en har ingen felles autostart-rekkefølge; MCP-en feiler hvis den starter før proxyen.
- Reverse-tunnelen på Mac-en er ikke dokumentert her: det er ikke undersøkt hva som starter og gjenoppretter den.
