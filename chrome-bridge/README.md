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
| MCP-en melder «Bad Gateway» på 9229, men `curl` fra shellen gir 200 | 502 kommer fra **proxyen selv**: den svarer 502 når oppslaget mot `:9222` ikke får svar på 5 s (`HTTP error: timed out` / `Connection reset by peer` i proxy-loggen). Det er ikke et MCP-miljøproblem (ingen `*_proxy`-variabler funnet). Tilstanden varer typisk sekunder (nettstall) eller så lenge Mac-en sover | Sjekk om Mac-en sov (`pmset -g log`) og om tunnelen ble startet på nytt; vent, deretter `/mcp` |
| Gjentatte `keepalive ping timeout` → `upstream dropped` i proxy-loggen mens Mac-en er våken | Nettverksstall mellom Mac og devbox. Se «Nettverk» under | Se «Nettverk» |
| `Requesting main frame too early` / `No page found` / fane-ID-ene endrer seg mellom kall | Klienten fikk en ny forbindelse (proxyen lukket den med 1011 etter et brudd) og MCP-en nummererer fanene på nytt; ID-er fra før bruddet peker på ingenting | `list_pages` på nytt; ved gjentatte brudd, se «Nettverk» |
| Tomme `about:blank`-faner hoper seg opp | `new_page` oppretter fanen i Chrome med en gang, men hvis kallet timer ut eller forbindelsen faller før svaret når klienten, blir fanen stående uten eier *(utledet, ikke sett i logg: proxyen logger ikke `createTarget`)* | Lukk dem manuelt; hver sesjon bør bare lukke faner den selv åpnet |

## Mac-dvale (verifisert årsak til brudd)

2026-11-13: proxy-loggen viste `ConnectionClosedError` kl. 21:38:40 CET, `keepalive ping timeout` og `upstream connect failed` hvert 11. s til 21:41:42. `pmset -g log` viste Idle Sleep 21:38:45 og Wake 21:41:17 (på batteri). Chrome og tunnelen var altså frosset mens Mac-en sov.

Forebygging: `caffeinate -i` på Mac-en mens du jobber mot devboxen, eller skru av dvale på batteri. Etter at Mac-en har sovet må en gammel MCP-sesjon kobles til på nytt (`/mcp`).

Launcheren starter `caffeinate -i -t 86400 -w $$` (maks 24 t, følger launcher-prosessen). **Et launcher-vindu som står åpent lenger enn taket (eller ble startet før taket ble endret) beskytter ikke lenger mot dvale**: scriptet leses inn ved start, så et kjørende vindu beholder gammel verdi. Verifisert 2026-11-19/20: vinduet var 25 t gammelt, ingen `caffeinate` knyttet til det, og Mac-en sov (2026-11-19 14:03–14:11 CET, 2026-11-20 16:12–16:19 CET). Proxy-loggen viste i samme minutter en serie 502 hvert 15. s (`/json/version`), og tunnelen var 1 minutt gammel da Mac-en var våken igjen (den ble startet på nytt av det som eier den). Lukk og åpne launcher-vinduet på nytt for en ny `caffeinate`.

Lukket lokk gir dvale uansett; `caffeinate -i` hindrer bare idle-dvale.

## Nettverk (utledet fra korrelasjon, ikke bevist rotårsak)

Mønster 2026-11-17/18 på et kontornett (WPA2 Enterprise): `tailscale netcheck` ga `UDP: false` på Mac-en, så trafikken til devboxen gikk via et Tailscale-relé (DERP, ~85 ms; `tailscale ping` melder «direct connection not established»), mens devboxen selv hadde UDP. Tailscale meldte også «The MagicSock function ReceiveIPv4 is not running». Over reléet kom det stall på 10–60 s, med tap og 500–1800 ms i vanlig ping.

Belegg:
- Proxy-logg (`keepalive ping timeout` / `upstream dropped` / 502 på `/json/version`) falt i samme minutter som tap og treghet i en ping mot devboxen (logget sekundvis, kun treg/tap, med minuttsammendrag).
- Etter bytte til mobil-hotspot (UDP `true`, snitt ~90 ms, ingen tap i flere minutter) stoppet stallene, og bridgen og en separat `ssh -L`-forward virket igjen. På hotspot kom det likevel enkelte drop (to rundt 14:40 CET 2026-11-19, ~5 % ping-tap), så det er ikke «rent».
- Mac-dvale forklarer *ikke* disse bruddene (ingen dvale-hendelser i `pmset -g log` i vinduene).

Proxyens oppstrøms-keepalive er allerede lempelig (ping 20 s, gir opp etter 60 s). Å heve den ytterligere skjuler lengre stall, men en kommando midt i et stall henger da like lenge. Den varige løsningen er at nettverket tillater utgående UDP (STUN 3478 og Tailscales UDP-port 41641), slik at Tailscale får en direkte forbindelse.

Nyttige kommandoer på Mac-en:

```bash
tailscale netcheck | grep -E 'UDP|IPv4'      # UDP: false = reléet brukes
tailscale ping -c 20 <devbox-host>             # via DERP(...) eller direkte?
ping -c 20 <devbox-tailscale-ip>               # tap/treghet over tid
```

Tailnettet kan inneholde andre personers enheter: pinge alltid din egen Mac/devbox på IP, ikke «første macOS-peer».

## Delt Chrome (flere sesjoner)

Hver Claude-sesjon har sin egen MCP-prosess, men alle snakker med samme Chrome via proxyen: samme profil, samme fanelister. chrome-devtools-mcp krever som standard `pageId` på sidespesifikke verktøy (`--no-page-id-routing` slår det av). Konsekvenser:
- `new_page` gir hver sesjon sin egen fane.
- Navigerer to sesjoner i den samme eksisterende fanen, vinner den siste, og den andre mister siden/DOM-referanser.
- Regel som fungerer: åpne egen fane med `new_page`, bruk bare den, lukk den når du er ferdig.

## Diagnoseprober (2026-11-18, utenfor den feilende sesjonen)

Mens en devbox-sesjon rapporterte brudd, ble hver del testet for seg fra devboxen; alt fungerte:
- Enkel CDP-klient mot proxyen (`:9228`): `setDiscoverTargets`, `attachToTarget` (flatten), `Runtime.evaluate` på 0,08–0,29 s, og forbindelsen holdt 75 s uten aktivitet.
- puppeteer 1.13.0-bunten fra chrome-devtools-mcp, `connect({browserURL})` via `:9229` og direkte `:9222`: `pages()` og `evaluate("location.href")` OK på alle faner, tre runder.
- `Target.createTarget` / `closeTarget` via proxyen: 0,27 s / 0,08 s.
- Fersk `chrome-devtools-mcp@1.13.0 --browser-url=http://127.0.0.1:9229` over stdio: `initialize`, `list_pages`, `new_page`, `list_pages` ×2 OK, stabil nummerering. `evaluate_script` via MCP ble ikke testet.

Konklusjon: Chrome, tunnel, proxy og en fersk MCP-prosess virker. Feil som «main frame too early» på en enkelt sesjon er ikke reprodusert utenfor sesjonen; årsaken der er ukjent (nettstall på det tidspunktet er én mulighet, en MCP-prosess som har levd lenge en annen).

## Status og restart i herdr (devbox)

Herdr kan vise bridge-status i tab-linjen og binde en tast til proxy-restart. Begge kjører på herdr-serveren (devboxen):

```toml
# ~/.config/herdr/config.toml på devboxen
[[keys.command]]
key = "prefix+alt+c"
type = "shell"
command = "systemctl --user restart cdp-devtools-filter-proxy"
description = "Restart Chrome bridge proxy"

[ui]
tab_bar_right = [
  { type = "command", command = "~/.config/herdr/scripts/chrome-bridge-status.sh", interval_seconds = 5, timeout_seconds = 3 },
]
tab_bar_right_separator = " · "
```

`chrome-bridge-status.sh` kjører `curl -s -m 2 -o /dev/null -w "%{http_code}" http://127.0.0.1:9229/json/version` og skriver `chrome ✓` ved 200, ellers `chrome ✗ <kode>`. Anvend med `herdr --session <session> server reload-config` (en navngitt sesjon har egen socket; uten `--session` svarer `server_not_running`).

Begrensninger: indikatoren viser bare at 9229 svarer, ikke hvilket ledd som er nede. Tasten starter bare proxyen; tunnelen og Chrome ligger på Mac-en og kan ikke startes fra devboxen. En proxy-restart lukker alle tilkoblede klienter (kjør `/mcp` etterpå). Herdr støtter ikke klikkbare knapper for slike entries, bare taster.

## Test av proxyens bruddoppførsel

Start en TCP-relé mellom proxyen og Chrome, koble en klient til proxyen, drep releet, og sjekk at klienten lukkes med 1011 (ikke henger):

```bash
CDP_UPSTREAM_PORT=9239 CDP_HTTP_PORT=9249 CDP_WS_PORT=9248 python cdp-devtools-filter-proxy.py   # relé: 9239 -> 9222
```

Kjørt 2026-11-13: klient lukket etter 0,01 s med `code=1011 reason='upstream dropped'`.

## Kjente svakheter

- Supervisor-helsesjekken er kun HTTP, ikke WS; den dreper aldri en MCP-prosess med død WS. Om `chrome-devtools-mcp` tar opp en ny sesjon av seg selv etter 1011 er ikke testet mot en ekte, langlevd MCP-sesjon (en fersk prosess over stdio virker, se «Diagnoseprober»). Sesjoner har rapportert at nettleseren «kobler til på nytt» og at kall nummer to etter `list_pages` feiler; det er ikke forklart.
- Ping-overvåkingen brukt under feilsøking var et midlertidig skript i `/tmp` og døde uforklart etter noen timer; det finnes ingen fast overvåking av nettverket mellom Mac og devbox.
- Proxyen og MCP-en har ingen felles autostart-rekkefølge; MCP-en feiler hvis den starter før proxyen.
- Reverse-tunnelen på Mac-en er ikke dokumentert her: det er ikke undersøkt hva som starter og gjenoppretter den.
