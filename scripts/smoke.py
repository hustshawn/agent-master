#!/usr/bin/env python3
"""End-to-end smoke test: real interactive claude -> agentmaster-hook -> fake AgentMaster socket.

Usage: scripts/smoke.py   (claude: ~/.local/bin/claude or $AGENTMASTER_CLAUDE_PATH;
                          hook: `swift build` output or $AGENTMASTER_HOOK_PATH)
Costs a few cents of haiku tokens. Exits 0 on PASS.
"""
import json, os, pty, re, select, shutil, socket, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRIP = {"CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
         "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
         "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_JOB_DIR", "CLAUDE_EFFORT",
         "TERM_PROGRAM", "TERM_PROGRAM_VERSION"}
REQUIRED = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"}
PROMPT = ("Do these steps in order without asking me anything: "
          "1) create a task with the TaskCreate tool whose subject is 'Fix add'; "
          "2) edit app.py so add() returns a + b; "
          "3) run the bash command: echo smoke-done; "
          "4) reply with just the word Finished.")


class FakeApp(threading.Thread):
    """Records every message; answers requests with an empty reply (handle in terminal)."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path, self.messages, self.lock = path, [], threading.Lock()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(16)

    def run(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                if not data.strip():
                    continue
                message = json.loads(data)
                with self.lock:
                    self.messages.append(message)
                if message.get("kind") == "request":
                    conn.sendall((json.dumps({"id": message["id"]}) + "\n").encode())

    def snapshot(self):
        with self.lock:
            return list(self.messages)


def visible(raw):
    """Terminal output without escape sequences or whitespace (the TUI draws spaces as cursor moves)."""
    text = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>]", b"", raw)
    return re.sub(rb"\s+", b"", text)


def event_names(messages):
    return [m.get("payload", {}).get("hook_event_name") or m.get("kind") or "?"
            for m in messages if m.get("kind") != "statusline"]


def main():
    claude = os.environ.get("AGENTMASTER_CLAUDE_PATH") or os.path.expanduser("~/.local/bin/claude")
    if not os.access(claude, os.X_OK):
        sys.exit(f"FAIL: claude not found at {claude}")

    hook = os.environ.get("AGENTMASTER_HOOK_PATH")
    if not hook:
        subprocess.run(["swift", "build", "--product", "agentmaster-hook"], cwd=ROOT, check=True)
        bin_dir = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True,
                                 capture_output=True, text=True).stdout.strip()
        hook = os.path.join(bin_dir, "agentmaster-hook")

    scratch = tempfile.mkdtemp(prefix="am-smoke-", dir="/tmp")
    work = os.path.join(scratch, "work")
    os.makedirs(work)
    with open(os.path.join(work, "app.py"), "w") as f:
        f.write("def add(a, b):\n    return a - b\n")
    settings = os.path.join(scratch, "settings.json")
    with open(settings, "wb") as f:
        f.write(subprocess.run([hook, "settings"], check=True, capture_output=True).stdout)

    sock = os.path.join(scratch, "am.sock")
    app = FakeApp(sock)
    app.start()

    env = {k: v for k, v in os.environ.items()
           if k not in STRIP and not k.startswith(("CMUX_", "AGENTMASTER_"))}
    env.update(TERM="xterm-256color", COLORTERM="truecolor", AGENTMASTER_SESSION_ID="SMOKE", AGENTMASTER_SOCKET=sock)
    env.setdefault("LANG", "en_US.UTF-8")

    args = [claude, "--settings", settings, "--model", "haiku", "--permission-mode", "acceptEdits",
            "--allowedTools", "Bash(echo:*)"]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execve(claude, args, env)

    deadline, screen, trusted, prompted, exited_at = time.time() + 240, b"", False, False, None
    try:
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                screen = (screen + chunk)[-20000:]
            if not trusted and b"Entertoconfirm" in visible(screen):
                time.sleep(0.5)
                os.write(fd, b"\x1b[B")    # "Yes, I trust this folder" is the second option
                time.sleep(0.5)
                os.write(fd, b"\r")        # separate write, or the TUI reads it as one escape sequence
                trusted = True
                screen = b""
            if not prompted and b"shift+tabtocycle" in visible(screen):
                # A prompt passed on the command line is dropped when the trust dialog shows, so type it.
                time.sleep(1)
                os.write(fd, PROMPT.encode())
                time.sleep(1)
                os.write(fd, b"\r")
                prompted = True
            names = event_names(app.snapshot())
            if "Stop" in names and exited_at is None:
                time.sleep(1)
                os.write(fd, b"/exit")
                time.sleep(0.5)
                os.write(fd, b"\r")
                exited_at = time.time()
            if "SessionEnd" in names:
                break
    finally:
        try:
            os.kill(pid, 9)
        except (ProcessLookupError, PermissionError):
            pass
        os.waitpid(pid, 0)
        app.server.close()

    messages = app.snapshot()
    names = event_names(messages)
    failures = []
    missing = REQUIRED - set(names)
    if missing:
        failures.append(f"missing hook events: {sorted(missing)}")
    if not any(m.get("kind") == "statusline" for m in messages):
        failures.append("no statusline message")
    posts = [m.get("payload", {}) for m in messages if m.get("payload", {}).get("hook_event_name") == "PostToolUse"]
    if not any(p.get("tool_name") == "TaskCreate" and (p.get("tool_response") or {}).get("task", {}).get("id")
               for p in posts):
        failures.append("TaskCreate PostToolUse without tool_response.task.id")
    if not any(p.get("tool_name") in ("Edit", "MultiEdit") and (p.get("tool_response") or {}).get("structuredPatch")
               for p in posts):
        failures.append("Edit PostToolUse without a non-empty structuredPatch")
    if any(m.get("sessionId") != "SMOKE" for m in messages):
        failures.append("a message was not tagged with AGENTMASTER_SESSION_ID")

    print(f"{len(messages)} messages: {names}")
    if failures:
        print("FAIL:\n  " + "\n  ".join(failures))
        with open(os.path.join(scratch, "screen.log"), "wb") as f:
            f.write(screen)
        print(f"(scratch kept at {scratch}; last terminal output in screen.log)")
        sys.exit(1)
    try:
        shutil.rmtree(scratch)
    except OSError as error:
        print(f"warning: could not remove scratch dir {scratch}: {error}")
    print("PASS")


if __name__ == "__main__":
    main()
