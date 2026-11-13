#!/usr/bin/env python3
# Sits between a chrome-devtools-mcp client and a real Chrome's CDP
# endpoint. Verified root cause: once a real Chrome DevTools inspector
# window is attached to any target, Target.getTargets over the live CDP
# WebSocket hangs for ~54-60s and then the connection gets torn down —
# even though the plain HTTP /json/list endpoint keeps responding fast
# the whole time. One human manually poking around with DevTools on a
# Chrome that automated sessions also share is enough to make every one
# of those sessions see constant "reconnected" / "No page found" errors.
#
# This proxy works around that without requiring a dedicated profile for
# manual use:
#   - intercepts Target.getTargets and answers it from the HTTP
#     endpoint instead of forwarding it upstream, so it never blocks on
#     whatever is making the live WS command hang
#   - filters devtools://... targets out of every list/event, so
#     automation never sees (or tries to act on) a real inspector window
#   - reconnects its upstream link to Chrome transparently if that link
#     drops, instead of tearing down the client's session
#
# Usage: point chrome-devtools-mcp at this instead of the real Chrome:
#   # before
#   --browser-url=http://127.0.0.1:9222
#   # after
#   --browser-url=http://127.0.0.1:9229   (or --ws-endpoint=ws://127.0.0.1:9228/devtools/browser/<id>)
#
# Env vars: CDP_UPSTREAM_HOST, CDP_UPSTREAM_PORT (default 9222),
# CDP_HTTP_PORT (default 9229), CDP_WS_PORT (default 9228).
import asyncio, json, os, threading, http.server, urllib.request, sys
from datetime import datetime
import websockets

UPSTREAM_HOST = os.environ.get("CDP_UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("CDP_UPSTREAM_PORT", "9222"))
HTTP_PORT = int(os.environ.get("CDP_HTTP_PORT", "9229"))
WS_PORT = int(os.environ.get("CDP_WS_PORT", "9228"))

def log(msg):
    # The proxy's own stdout/stderr is otherwise the only record of what
    # it did and when -- without a timestamp there's no way to tell a
    # today's-activity log line from one from days ago.
    print(f"{datetime.now().strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]} {msg}", file=sys.stderr)

def filtered_list():
    url = f"http://{UPSTREAM_HOST}:{UPSTREAM_PORT}/json/list"
    with urllib.request.urlopen(url, timeout=5) as r:
        data = json.load(r)
    out = []
    for t in data:
        if t.get("url", "").startswith("devtools://"):
            continue
        if "webSocketDebuggerUrl" in t:
            t["webSocketDebuggerUrl"] = t["webSocketDebuggerUrl"].replace(
                f"{UPSTREAM_HOST}:{UPSTREAM_PORT}", f"{UPSTREAM_HOST}:{WS_PORT}"
            )
        out.append(t)
    return out

def target_infos_via_http():
    infos = []
    for t in filtered_list():
        infos.append({
            "targetId": t.get("id", ""),
            "type": t.get("type", "page"),
            "title": t.get("title", ""),
            "url": t.get("url", ""),
            "attached": True,
            "canAccessOpener": False,
        })
    return infos

def version_rewritten():
    url = f"http://{UPSTREAM_HOST}:{UPSTREAM_PORT}/json/version"
    with urllib.request.urlopen(url, timeout=5) as r:
        data = json.load(r)
    data["webSocketDebuggerUrl"] = data["webSocketDebuggerUrl"].replace(
        f"{UPSTREAM_HOST}:{UPSTREAM_PORT}", f"{UPSTREAM_HOST}:{WS_PORT}"
    )
    return data

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log("HTTP " + (fmt % args))

    def _send_json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        try:
            if self.path in ("/json/list", "/json"):
                self._send_json(filtered_list())
            elif self.path == "/json/version":
                self._send_json(version_rewritten())
            else:
                self.send_response(404)
                self.end_headers()
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            log(f"HTTP error: {e}")

def run_http():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), Handler)
    srv.serve_forever()

def should_drop(msg_obj):
    method = msg_obj.get("method", "")
    if method in (
        "Target.targetCreated",
        "Target.attachedToTarget",
        "Target.targetInfoChanged",
        "Target.targetDestroyed",
    ):
        ti = msg_obj.get("params", {}).get("targetInfo", {})
        if ti.get("url", "").startswith("devtools://"):
            return True
    return False

def filter_target_infos(msg_obj):
    result = msg_obj.get("result", {})
    if isinstance(result, dict) and "targetInfos" in result:
        result["targetInfos"] = [
            t for t in result["targetInfos"]
            if not t.get("url", "").startswith("devtools://")
        ]
    return msg_obj

async def pump_upstream_to_client(upstream, client):
    async for raw in upstream:
        try:
            obj = json.loads(raw)
        except Exception:
            await client.send(raw)
            continue
        if should_drop(obj):
            log(f"FILTERED event dropped: {obj.get('method')}")
            continue
        obj = filter_target_infos(obj)
        try:
            await client.send(json.dumps(obj))
        except websockets.exceptions.ConnectionClosed:
            return

async def pump_client_to_upstream(client, upstream):
    async for raw in client:
        try:
            obj = json.loads(raw)
        except Exception:
            await upstream.send(raw)
            continue
        if obj.get("method") == "Target.getTargets":
            reply = {"id": obj.get("id"), "result": {"targetInfos": target_infos_via_http()}}
            if "sessionId" in obj:
                reply["sessionId"] = obj["sessionId"]
            log("INTERCEPTED Target.getTargets -> served via HTTP, not forwarded")
            await client.send(json.dumps(reply))
            continue
        try:
            await upstream.send(raw)
        except websockets.exceptions.ConnectionClosed:
            return

async def handle_client(client):
    # Chrome has been observed to reset the proxy's upstream socket
    # independently of the client. A hard failure here must not take the
    # client's session down with it -- reconnect upstream transparently
    # and keep serving the same client, instead of forcing
    # chrome-devtools-mcp to redo its whole handshake.
    path = client.request.path
    upstream_url = f"ws://{UPSTREAM_HOST}:{UPSTREAM_PORT}{path}"
    while True:
        try:
            upstream = await websockets.connect(upstream_url, max_size=None, open_timeout=10)
        except Exception as e:
            log(f"upstream connect failed: {e!r}")
            await asyncio.sleep(1)
            if client.close_code is not None:
                return
            continue

        async with upstream:
            t_up = asyncio.create_task(pump_upstream_to_client(upstream, client))
            t_down = asyncio.create_task(pump_client_to_upstream(client, upstream))
            done, pending = await asyncio.wait({t_up, t_down}, return_when=asyncio.FIRST_COMPLETED)
            for p in pending:
                p.cancel()
            for d in done:
                exc = d.exception()
                if exc is not None:
                    log(f"pump ended: {exc!r}")

        if client.close_code is not None:
            return
        log("upstream dropped, reconnecting (client session kept alive)")
        await asyncio.sleep(0.3)

async def run_ws():
    async with websockets.serve(handle_client, "127.0.0.1", WS_PORT, max_size=None):
        await asyncio.Future()

if __name__ == "__main__":
    threading.Thread(target=run_http, daemon=True).start()
    log(f"HTTP filter proxy on :{HTTP_PORT} -> upstream :{UPSTREAM_PORT}")
    log(f"WS filter proxy on :{WS_PORT} -> upstream :{UPSTREAM_PORT}")
    asyncio.run(run_ws())
