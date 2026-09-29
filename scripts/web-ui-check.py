#!/usr/bin/env python3
"""Drives the web UI in headless Chromium against agentmaster-server and the real Claude Code, and saves a
screenshot of each step. Covers: token login, new session, typing into the agent's terminal, the inspector's
file change, Settings, rename, reload (sessions and terminal come back), close.

Usage: uv run --with playwright scripts/web-ui-check.py [--out /tmp/ui-shots]
       (first time: uv run --with playwright python -m playwright install chromium)
Costs a few cents of model tokens. Exits 0 on PASS.
"""
import argparse, os, shutil, socket, subprocess, sys, tempfile, time

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TERMINAL = ".term-pane:not([hidden]) .xterm-rows"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="/tmp/ui-shots", help="where to save the screenshots")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for product in ("agentmaster-server", "agentmaster-hook"):
        subprocess.run(["swift", "build", "--product", product], cwd=ROOT, check=True)
    bin_dir = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True,
                             capture_output=True, text=True).stdout.strip()

    scratch = tempfile.mkdtemp(prefix="am-ui-", dir="/tmp")
    work = os.path.join(scratch, "demo-project")
    os.makedirs(work)
    with open(os.path.join(work, "app.py"), "w") as f:
        f.write("def add(a, b):\n    return a - b\n")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    log = open(os.path.join(scratch, "server.log"), "w")
    server = subprocess.Popen([os.path.join(bin_dir, "agentmaster-server"), "--port", str(port),
                               "--data-dir", os.path.join(scratch, "data"), "--token", "ui-token"],
                              stdout=log, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    errors, step = [], "start"
    try:
        time.sleep(2)
        with sync_playwright() as p:
            browser = p.chromium.launch()
            page = browser.new_page(viewport={"width": 1440, "height": 860})
            page.on("pageerror", lambda e: errors.append(f"pageerror: {e}"))
            page.on("console", lambda m: errors.append(f"console.error: {m.text}")
                    if m.type == "error" and "401" not in m.text else None)   # the wrong-token step is expected
            page.on("dialog", lambda d: d.accept())
            shot = lambda name: page.screenshot(path=os.path.join(args.out, name + ".png"))

            try:
                step = "login"
                page.goto(base + "/")
                page.wait_for_selector("#login:not([hidden])")
                page.fill("#login-token", "wrong")
                page.click("#login-form button")
                page.wait_for_selector("#login-error:not([hidden])")
                page.goto(base + "/#token=ui-token")
                page.wait_for_selector("#app:not([hidden])")
                assert "token" not in page.url, "the token stayed in the address bar"
                shot("1-empty")

                step = "new session"
                page.click("#new-session")
                page.wait_for_selector("#new-dialog[open]")
                page.fill("#new-project", work)
                shot("2-new-session")
                page.click("#new-start")
                page.wait_for_selector(".row-item")

                step = "the agent's first-run prompt"
                ready = f"/shift\\+tab|\\? for shortcuts/.test(document.querySelector('{TERMINAL}')?.innerText)"
                trust = f"document.querySelector('{TERMINAL}')?.innerText.includes('trust this folder')"
                page.wait_for_function(f"({ready}) || ({trust})", timeout=90000)
                page.click(".term-pane:not([hidden])")
                time.sleep(0.5)   # the terminal takes focus on the next frame
                if page.evaluate(trust):   # Claude asks only for folders it has not been trusted in
                    shot("3-trust")
                    page.keyboard.press("ArrowDown")
                    time.sleep(0.4)
                    page.keyboard.press("Enter")
                    page.wait_for_function(ready, timeout=60000)

                step = "a task through the terminal"
                time.sleep(1)
                page.keyboard.type("Edit app.py so add() returns a + b. Do not ask me anything.")
                page.keyboard.press("Enter")
                # Running (◈), then idle again (◇) once the turn ends.
                page.wait_for_function("document.querySelector('.row-item .glyph')?.innerText === '◈'", timeout=60000)
                page.wait_for_function("document.querySelector('.row-item .glyph')?.innerText === '◇'", timeout=240000)
                with open(os.path.join(work, "app.py")) as f:
                    assert "a + b" in f.read(), "the agent did not edit app.py"
                # CHANGES lists Edit/Write edits; the model may also edit through Bash, which it does not see.
                if page.query_selector(".change summary"):
                    page.click(".change summary")
                    assert page.inner_text(".change summary").startswith("app.py"), "the change is not relative to the project"
                shot("4-session")

                step = "settings"
                page.click("#open-settings")
                page.wait_for_selector("#settings-dialog[open] .option")
                shot("5-settings")
                page.click("#settings-close")

                step = "rename"
                page.dblclick(".row-item")
                page.fill(".row-item input", "Renamed in browser")
                page.keyboard.press("Enter")
                page.wait_for_function("document.querySelector('.row-item .title')?.innerText === 'Renamed in browser'")

                step = "reload"
                page.reload()
                page.wait_for_selector(".row-item")
                page.wait_for_function(f"(document.querySelector('{TERMINAL}')?.innerText || '').length > 50")
                shot("6-after-reload")

                step = "close"
                page.hover(".row-item")
                page.click(".row-item .close")
                page.wait_for_selector("#empty:not([hidden])")
            except Exception:
                shot("failed")
                raise
            browser.close()
    except Exception as error:
        errors.append(f"{step}: {error}")
    finally:
        server.terminate()
        server.wait(timeout=10)
        log.close()

    if errors:
        print("FAIL:\n  " + "\n  ".join(errors))
        print(f"(scratch kept at {scratch}; screenshots in {args.out})")
        return 1
    shutil.rmtree(scratch, ignore_errors=True)
    print(f"PASS (screenshots in {args.out})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
