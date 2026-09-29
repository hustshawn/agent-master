#!/usr/bin/env python3
"""End-to-end check of the web edition: agentmaster-server + a real agent, driven only through the HTTP and
WebSocket API the browser uses.

Usage: uv run --with websockets scripts/web-smoke.py [--agent claude|codex] [--server PATH]
Starts the server on a free port with a scratch data directory, sets the agent's defaults through the API,
starts a session in a scratch project, answers the agent's first-run prompts, sends one task that edits a
file, and checks that the session state (status, first prompt, file change) and the terminal stream arrive.
Costs a few cents of model tokens. Exits 0 on PASS.
"""
import argparse, asyncio, json, os, re, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request

import websockets

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT = ("Do these steps in order without asking me anything: 1) edit app.py so add() returns a + b; "
          "2) run the shell command: echo smoke-done; 3) reply with just the word Finished.")
# Per agent: the defaults to set through the API, so the scratch run needs no approvals.
DEFAULTS = {
    "claude": {"model": "haiku", "permissionMode": "bypassPermissions"},
    "codex": {"sandbox": "workspace-write", "approval": "never"},
}


def visible(raw):
    """Terminal output without escape sequences or whitespace (TUIs draw spaces as cursor moves)."""
    text = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>]", b"", raw)
    return re.sub(rb"\s+", b"", text)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Api:
    def __init__(self, base, token):
        self.base, self.token = base, token

    def call(self, method, path, body=None, token=True):
        request = urllib.request.Request(self.base + path, method=method,
                                         data=None if body is None else json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
        if token:
            request.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = response.read()
                is_json = "json" in (response.headers.get("Content-Type") or "")
                return response.status, json.loads(data) if data and is_json else data
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode(errors="replace")


async def run(args):
    if not args.server:
        subprocess.run(["swift", "build", "--product", "agentmaster-server"], cwd=ROOT, check=True)
        subprocess.run(["swift", "build", "--product", "agentmaster-hook"], cwd=ROOT, check=True)
        bin_dir = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True,
                                 capture_output=True, text=True).stdout.strip()
        args.server = os.path.join(bin_dir, "agentmaster-server")

    scratch = tempfile.mkdtemp(prefix="am-web-", dir="/tmp")
    work = os.path.join(scratch, "work")
    os.makedirs(work)
    with open(os.path.join(work, "app.py"), "w") as f:
        f.write("def add(a, b):\n    return a - b\n")
    port, token = free_port(), "smoke-token"
    log = open(os.path.join(scratch, "server.log"), "w")
    api = Api(f"http://127.0.0.1:{port}", token)

    def start_server():
        process = subprocess.Popen([args.server, "--port", str(port), "--data-dir", os.path.join(scratch, "data"),
                                    "--token", token], stdout=log, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                if api.call("GET", "/api/recents")[0] == 200:
                    return process
            except OSError:
                pass
            time.sleep(0.2)
        raise SystemExit(f"FAIL: server did not start (see {scratch}/server.log)")

    failures, screen, events = [], b"", []
    server = start_server()
    try:

        if api.call("GET", "/api/sessions", token=False)[0] != 401:
            failures.append("/api without the token was not rejected")
        status, page = api.call("GET", "/", token=False)[0], None
        if status != 200:
            failures.append(f"the web page returned {status}")
        status, agents = api.call("GET", "/api/agents")
        agent = next((a for a in agents["agents"] if a["id"] == args.agent), None)
        if not agent or not agent["location"]:
            raise SystemExit(f"FAIL: {args.agent} is not installed on this machine")
        for option, value in DEFAULTS[args.agent].items():
            status, body = api.call("PUT", f"/api/agents/{args.agent}/options/{option}", {"value": value})
            if status != 204:
                failures.append(f"setting {option} returned {status}: {body}")

        async with websockets.connect(f"ws://127.0.0.1:{port}/api/events?token={token}") as feed:
            snapshot = json.loads(await feed.recv())
            if snapshot["type"] != "snapshot":
                failures.append("the event stream did not start with a snapshot")
            status, session = api.call("POST", "/api/sessions",
                                       {"projectPath": work, "agentId": args.agent, "columns": 120, "rows": 40})
            if status != 200:
                raise SystemExit(f"FAIL: creating the session returned {status}: {session}")
            sid = session["id"]

            async def collect():
                async for message in feed:
                    events.append(json.loads(message))

            collector = asyncio.create_task(collect())
            url = f"ws://127.0.0.1:{port}/api/terminal?id={sid}&token={token}"
            async with websockets.connect(url, max_size=None) as term:
                async def send(text):
                    await term.send(json.dumps({"type": "input", "data": text}))

                answered, prompted, deadline, quiet_since = set(), False, time.time() + 300, time.time()
                while time.time() < deadline:
                    try:
                        chunk = await asyncio.wait_for(term.recv(), timeout=0.5)
                        screen = (screen + chunk)[-60000:]
                        quiet_since = time.time()
                    except asyncio.TimeoutError:
                        pass
                    flat = visible(screen)
                    if "update" not in answered and b"1.Updatenow" in flat and b"Pressentertocontinue" in flat:
                        answered.add("update")   # codex: "2. Skip" this once
                        await send("\x1b[B"); await asyncio.sleep(0.5); await send("\r")
                        screen = b""
                        continue
                    # Claude's folder trust dialog, then Codex's (worded differently across Codex versions).
                    if "trust" not in answered and (b"Entertoconfirm" in flat or b"Doyoutrustthecontents" in flat
                                                    or b"Trustthisfolder?" in flat):
                        answered.add("trust")
                        if args.agent == "claude":
                            await asyncio.sleep(0.5); await send("\x1b[B")   # "Yes, I trust this folder"
                        await asyncio.sleep(0.5); await send("\r")
                        screen = b""
                        continue
                    if not prompted and time.time() - quiet_since > 3 and len(screen) > 0:
                        await send(PROMPT); await asyncio.sleep(1); await send("\r")
                        prompted = True
                    latest = next((e["session"] for e in reversed(events) if e.get("session", {}).get("id") == sid), None)
                    if prompted and latest and latest["state"].get("lastMessage") and latest["status"] == "idle":
                        break

                # A second browser (or a reload) gets the scrollback first.
                async with websockets.connect(url, max_size=None) as again:
                    replay = await asyncio.wait_for(again.recv(), timeout=5)
                    if len(replay) < 100:
                        failures.append("a reconnecting terminal got no scrollback")

            if args.restart:
                collector.cancel()
            else:
                status, _ = api.call("DELETE", f"/api/sessions/{sid}")
                if status != 204:
                    failures.append(f"closing the session returned {status}")
                await asyncio.sleep(1)
                collector.cancel()

        if args.restart:
            # Stop the server the way systemd does, start it again on the same data directory: the session
            # comes back and the agent resumes its conversation.
            conversation = next((e["session"] for e in reversed(events) if e.get("session", {}).get("id") == sid), None)
            server.terminate()
            server.wait(timeout=20)
            server = start_server()
            status, listing = api.call("GET", "/api/sessions")
            restored = listing["sessions"] if status == 200 else []
            if len(restored) != 1:
                failures.append(f"after a restart {len(restored)} sessions came back, not 1")
            else:
                if restored[0]["title"] != conversation["title"]:
                    failures.append(f"the restored title is {restored[0]['title']!r}, not {conversation['title']!r}")
                flag = "--resume" if args.agent == "claude" else "resume"
                agents = subprocess.run(["ps", "-ax", "-o", "ppid=,args="], capture_output=True, text=True).stdout
                resumed = [line for line in agents.splitlines()
                           if line.split(None, 1)[0] == str(server.pid) and f" {flag} " in line]
                if not resumed:
                    failures.append(f"the restored {args.agent} was not started with {flag}")
                print(f"restored: {restored[0]['title']!r}; relaunched with {flag}: {bool(resumed)}")
                api.call("DELETE", f"/api/sessions/{restored[0]['id']}")
            events.append({"type": "removed", "id": sid})

        mine = [e["session"] for e in events if e.get("session", {}).get("id") == sid]
        statuses = [s["status"] for s in mine]
        final = mine[-1] if mine else None
        if "running" not in statuses:
            failures.append(f"the session never showed as running (saw {sorted(set(statuses))})")
        if not final or not (final["state"].get("firstPrompt") or "").startswith("Do these steps"):
            failures.append("the first prompt did not reach the session state")
        if not final or not any(c["path"].endswith("/app.py") for c in final["state"]["changes"]):
            failures.append("the edit to app.py did not reach the session state")
        if not any(e["type"] == "removed" and e.get("id") == sid for e in events):
            failures.append("closing the session sent no removed event")
        with open(os.path.join(work, "app.py")) as f:
            if "a + b" not in f.read():
                failures.append("the agent did not edit app.py")
        print(f"{len(mine)} session updates, statuses {sorted(set(statuses))}; "
              f"changes {[c['path'] for c in final['state']['changes']] if final else []}")
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
        log.close()

    if failures:
        print("FAIL:\n  " + "\n  ".join(failures))
        with open(os.path.join(scratch, "screen.log"), "wb") as f:
            f.write(screen)
        print(f"(scratch kept at {scratch}: server.log, screen.log)")
        return 1
    if not args.keep:
        shutil.rmtree(scratch, ignore_errors=True)
    print("PASS")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", default="claude", choices=sorted(DEFAULTS))
    parser.add_argument("--server", help="a built agentmaster-server (agentmaster-hook must sit next to it)")
    parser.add_argument("--keep", action="store_true", help="keep the scratch directory")
    parser.add_argument("--restart", action="store_true",
                        help="also restart the server and check the session comes back resumed")
    sys.exit(asyncio.run(run(parser.parse_args())))


if __name__ == "__main__":
    main()
