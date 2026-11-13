# devbox-chrome-bridge

Lar `chrome-devtools-mcp` på devboxen (`devbox-jov-ne`) styre Chrome på Mac-en.

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
| Reverse-tunnel | Mac → devbox | 9222 | `ssh -N -T -R 9222:127.0.0.1:9222 jov@devbox-jov-ne` |
| Filter-proxy | devbox | 9229 (HTTP), 9228 (WS) | Se under |
| MCP-server | devbox | – | `--browser-url=http://127.0.0.1:9229` i `~/.claude.json`, startet via `chrome-mcp-supervisor.sh` |

**MCP-en skal peke på 9229, ikke 9222.** 9222 på devboxen er bare tunnelen rett til Chrome.

## Hvorfor en proxy

Når et ekte DevTools-vindu er festet til en fane, henger `Target.getTargets` over WebSocket i ca. 60 s, selv om HTTP `/json/list` svarer raskt. Proxyen:

- svarer på `Target.getTargets` fra HTTP-endepunktet i stedet for å sende det videre,
- filtrerer ut `devtools://`-mål fra lister og hendelser,
- kobler til Chrome på nytt hvis oppstrøms-forbindelsen faller.

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
loginctl enable-linger jov
```

Loggen ligger i `~/.local/state/cdp-proxy/proxy.log`.

## Sjekke status (bridgen er flere ledd – sjekk alle)

```bash
# 1) Mac: Chrome og tunnel
curl -s http://127.0.0.1:9222/json/version | head -3
ps -axo args= | grep -- '-R 9222'

# 2) devbox: tunnelen kommer frem, og proxyen lytter
ssh jov@devbox-jov-ne 'curl -s -m5 http://127.0.0.1:9222/json/version | head -3; ss -ltn | grep -E ":(9222|9228|9229)\b"'

# 3) devbox: proxyen svarer, og tjenesten er oppe
ssh jov@devbox-jov-ne 'curl -s -m5 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9229/json/version; systemctl --user is-active cdp-devtools-filter-proxy'
```

Å sjekke bare 9222 sier ingenting om MCP-en virker.

## Feilsøking

| Symptom | Sannsynlig årsak | Tiltak |
|---|---|---|
| `curl 127.0.0.1:9229` → connection refused | Proxyen kjører ikke (f.eks. etter reboot uten linger) | `systemctl --user start cdp-devtools-filter-proxy`; vurder `enable-linger` |
| 9222 virker, 9229 ikke | Samme som over – 9222 er bare tunnelen | Som over |
| `list_pages` virker, men `new_page` / `navigate_page` / skjermbilde henger | Gammel WS-forbindelse i MCP-prosessen etter at proxyen ble restartet. Helsesjekken i supervisoren tester bare HTTP, så den oppdager det ikke. *(Hypotese, ikke bekreftet mot en konkret prosess.)* | `/mcp` → reconnect i Claude Code-sesjonen |
| Kall mot en fane henger i det uendelige | Fane-ID-en finnes ikke lenger. Proxyen prøver å koble til på nytt hvert sekund og gir aldri en feil (`handle_client`). Direkte mot Chrome gir 404. | `list_pages` på nytt for ferske ID-er. Koden er ikke endret. |
| Lesing virker, men fanen «endrer seg ikke» | Fanen er skjult (`document.visibilityState == "hidden"`); Chrome throttler skjulte faner | Hent fanen frem først (`select_page`) |
| `ssh … Address already in use` for 8000/3332/8080/13000 | `LocalForward` i `~/.ssh/config` kolliderer med herdr-sesjonen | Ufarlig; bruk `-o ClearAllForwardings=yes` ved enkeltkommandoer |

## Kjente svakheter

- Proxyen avviser ikke kommandoer til ukjente fane-ID-er; de henger.
- Supervisor-helsesjekken er kun HTTP, ikke WS.
- Proxyen og MCP-en har ingen felles autostart-rekkefølge; MCP-en feiler hvis den starter før proxyen.
- Reverse-tunnelen på Mac-en er ikke dokumentert her: det er ikke undersøkt hva som starter og gjenoppretter den.
