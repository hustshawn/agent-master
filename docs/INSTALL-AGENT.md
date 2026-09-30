# Installing the AgentMaster server: instructions for an AI agent

You are an AI coding agent on a Linux machine. The user wants **AgentMaster's web edition** (`agentmaster-server`) running
here. Follow these steps in order. Each step says how to check it worked. **Stop and ask the user** where a step says
so. Do not guess past those points.

What you are installing: one server process. It runs coding-agent CLIs (`claude`, `codex`, `kiro-cli`) in pseudo-terminals and serves a
browser UI for them on one port. It installs into the user's home directory and runs as a systemd *user* service. Nothing
needs root.

## Ignore the Mac app

This repository also holds a native **macOS** app. None of it applies on a Linux server, so skip all of it:

- `AgentMaster.app`, the `.dmg` in each release, the "Download" and "Build and run" sections of the README
- Xcode, `xcodebuild`, the Metal toolchain
- `scripts/bundle.sh`, `scripts/make-dmg.sh`, `scripts/smoke.py`, `scripts/make-icon.swift`
- The `AgentMaster`, `AgentMasterUI` and `TerminalKit` targets. On Linux, `Package.swift` does not even declare them.

What you need is only the Linux server package, `agentmaster-server-<version>-linux-<arch>.tar.gz`, and `install-server.sh`. If
you have to build from source (step 3), only the server products are built. Do not install Xcode or any macOS tooling.

## Rules

- Install as the **user who will use it**, the one whose login shell runs `claude`/`codex`/`kiro-cli`. Never as root, and never with `sudo`,
  except for the single optional `loginctl` command in step 5, and only if the user agrees.
- Keep the server on `127.0.0.1` unless the user explicitly asks for another address. How it is reached from outside (SSH port
  forwarding, a load balancer, TLS) is the user's decision. Do not set it up.
- Do not edit the user's shell profiles, `~/.claude`, `~/.codex`, or `~/.kiro`. Do not delete `~/.agentmaster-server`. It holds the user's
  sessions, settings and access token.
- The access token grants shell access as this user. Show it only in your final report to the user. Never paste it into files,
  commits, issues or other tools.

## 1. Read this repository

The repository `hustshawn/agent-master` is private. A plain web fetch of github.com returns 404. Use the GitHub CLI:

```bash
gh auth status                                   # must say "Logged in to github.com"
gh repo view hustshawn/agent-master --json name -q .name     # prints: agent-master
```

- If `gh` is missing or not logged in, check whether `GITHUB_TOKEN` is set: `test -n "$GITHUB_TOKEN" && echo set`.
- If neither works, **stop and ask the user** to run `gh auth login` on this machine, or to give you a token that can read the
  repository.
- Do not try other ways in.

## 2. Check the machine

Run each check and compare with the expected result:

| Check | Command | Expected |
|---|---|---|
| OS and architecture | `uname -sm` | `Linux x86_64` or `Linux aarch64`. Anything else: stop and tell the user there is no prebuilt server for it |
| Not root | `id -u` | Not `0`. If it is `0`, stop and ask which user should own the install |
| Agents on the login PATH | `"$SHELL" -lic 'command -v claude; command -v codex; command -v kiro-cli' 2>/dev/null` | At least one path. The server finds agents through the login shell, so a binary that is only on your current PATH does not count |
| systemd user session | `systemctl --user show-environment >/dev/null && echo yes` | `yes`. If not, the installer falls back to `nohup` (see step 5) |
| Port free | `(exec 3<>/dev/tcp/127.0.0.1/8765) 2>/dev/null && echo busy \|\| echo free` | `free`. If `busy`, check whether it is already AgentMaster (step 4). Otherwise **ask the user** which port to use |
| Existing install | `ls ~/.local/share/agentmaster-server/current 2>/dev/null && systemctl --user is-active agentmaster-server` | Nothing (fresh install), or `active` (already installed: installing again upgrades it and keeps the data) |

If none of `claude`, `codex` and `kiro-cli` is found, tell the user. The server installs anyway, but sessions cannot start until one is
installed.

## 3. Install

Default install: latest release, `127.0.0.1:8765`.

```bash
gh release download -R hustshawn/agent-master -p install-server.sh -O - | bash
```

With a port the user chose, or a specific release:

```bash
gh release download -R hustshawn/agent-master -p install-server.sh -O - | bash -s -- --port 9000 --version v0.3.0
```

Without `gh`, using `GITHUB_TOKEN`:

```bash
curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github.raw" \
  https://api.github.com/repos/hustshawn/agent-master/contents/scripts/install-server.sh | bash
```

The installer finishes with a block that starts with `AgentMaster server <version> is running on …` and an `Open:` link. Keep
that output for your report.

**If the release has no package for this architecture** (`release … has no linux-<arch> package`, or `gh` reports no matching
asset), build it from source. That needs Swift 6.
1. Clone: `gh repo clone hustshawn/agent-master`.
2. In the clone, run `scripts/package-server.sh`.
3. Install the result: `bash scripts/install-server.sh --from build/agentmaster-server-linux-$(uname -m).tar.gz`.
If Swift is not installed, stop and tell the user. Do not install a toolchain without asking.

## 4. Verify

All of these must pass:

```bash
systemctl --user is-active agentmaster-server          # active   (skip under nohup, see step 5)
PORT=8765                                               # or the port you installed with
TOKEN="$(cat ~/.agentmaster-server/token)"
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$PORT/"                               # 200
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$PORT/api/agents"                     # 401 (the API needs the token)
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/agents" | grep -o '"location":"[^"]*"'
```

The last command prints one `"location":"…"` for each agent the server found, for example `"location":"\/home\/dev\/.local\/bin\/claude"`.
The escaped slashes are normal JSON. It should list the same agents as step 2. If it prints nothing, the server's login shell
does not find the agents. Tell the user which agent is missing from their login PATH.

## 5. If something fails

| Symptom | What to do |
|---|---|
| `note: run 'sudo loginctl enable-linger <user>'` | Without lingering, the service stops when the user's last login session ends. Ask the user whether you may run that one `sudo` command. Mention it in your report either way |
| `No systemd user session here; starting it in the background with nohup` | Fine on machines without systemd, such as containers. It will not restart after a reboot. Say so in your report, and say that rerunning the installer starts it again |
| `the server did not start on …` | Read `journalctl --user -u agentmaster-server -n 50` (or `~/.local/share/agentmaster-server/server.log` under nohup). If the port is in use, ask for another port and install again with `--port` |
| `log in with 'gh auth login', set GITHUB_TOKEN, …` | Go back to step 1 |
| `note: 'codex' is not on your login shell's PATH` | Only a warning. That agent's sessions will not start until it is installed |

Do not work around a failure by editing the installed files or the systemd unit by hand. Report what you saw instead.

## 6. Report to the user

End with this, filled in:

```
AgentMaster server <version> is running on <host>:<port> as a systemd user service (or: under nohup).
Agents found: <claude, codex, kiro-cli, …>
Open:   http://127.0.0.1:<port>/#token=<token>        (the token is also in ~/.agentmaster-server/token)
Reach it from your machine, e.g.:  ssh -L <port>:127.0.0.1:<port> <user>@<this host>
Manage: systemctl --user status|restart|stop agentmaster-server · logs: journalctl --user -u agentmaster-server -f
Upgrade: run the install command again · Remove: add --uninstall (keeps ~/.agentmaster-server)
<any warnings: lingering not enabled, nohup instead of systemd, an agent missing>
```
