<p align="center">
  <img src="Assets/AppIcon-1024.png" width="128" alt="AgentMaster icon">
</p>

> **AI agent asked to install AgentMaster on a (Linux) server?** Follow [docs/INSTALL-AGENT.md](docs/INSTALL-AGENT.md) and ignore the macOS app parts of this README.

# AgentMaster

[![Release](https://github.com/hustshawn/agent-master/actions/workflows/release.yml/badge.svg)](https://github.com/hustshawn/agent-master/actions/workflows/release.yml)
[![Download](https://img.shields.io/badge/download-latest-blue)](https://github.com/hustshawn/agent-master/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)
![Apple silicon](https://img.shields.io/badge/arch-Apple%20silicon-555)
![Agents](https://img.shields.io/badge/agents-Claude%20Code%20%7C%20Codex-D97757)
[![License: proprietary](https://img.shields.io/badge/license-proprietary-lightgrey)](LICENSE)

One native macOS app for all your coding-agent CLIs.

AgentMaster runs each agent's real TUI in an embedded terminal and manages them from one window. You get a session sidebar across projects and agents, live panels for the current session, and per-agent defaults. It does not reimplement any agent. Every CLI keeps its own harness and works exactly as it does in your terminal, with its own config, instructions, skills, MCP servers, hooks and plugins. AgentMaster only adds a thin, per-session layer on top.

## Supported agents

| Agent | Status and panels | Restore on launch | Header usage and cost |
|---|---|---|---|
| [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) | ✓ via hooks passed with `--settings` | ✓ `claude --resume` | ✓ via the status line |
| [OpenAI Codex CLI](https://github.com/openai/codex) | ✓ via hooks passed with `-c`, which needs `--dangerously-bypass-hook-trust` ([why](docs/adr/0009-codex-agent.md)) | ✓ `codex resume` | — |

More agents can be added without touching the UI. See [Adding an agent](#adding-an-agent).

## Features

- **Every agent in one sidebar.** Sessions are grouped by project, whichever agent runs them. Each session is titled by its first prompt, and you can rename it. Sessions from agents other than Claude Code are labelled with the agent's name, for example `Codex · idle`.
- **New session panel.** Every ＋ opens a panel where you choose the agent and, if you want, a model other than its default. ⌘N starts Claude Code in the current project, and ⌥⌘N starts Codex.
- **Restore on launch.** Sessions that were open when you quit come back and resume their conversations.
- **Review inspector.** A collapsible side panel (⌥⌘0) shows todos, subagents and file changes for the selected session.
- **Header status.** The model and permission mode, plus context usage and cost where the agent reports them.
- **Per-agent settings (⌘,).** Each agent has its own page. It shows where the binary was found and holds its defaults for new sessions, such as model, permission mode, sandbox and approval policy.
- **Non-invasive.** Hooks are injected into each session through the agent's own command-line options. AgentMaster never edits your global Claude Code or Codex configuration. If AgentMaster isn't running, every agent behaves as usual.

## Requirements

- macOS 14 or later
- Xcode 15.4 (Swift 5.10) or later
- At least one supported agent. Each is looked up in this order:

  | Agent | Override variable | Then |
  |---|---|---|
  | Claude Code | `AGENTMASTER_CLAUDE_PATH` | `~/.local/bin/claude`, Homebrew, `/usr/local/bin`, your login shell's `PATH` |
  | Codex CLI 0.154 or later | `AGENTMASTER_CODEX_PATH` | `~/.local/bin/codex`, Homebrew, `/usr/local/bin`, your login shell's `PATH` |

## Download

Each tagged version is published on the [Releases](https://github.com/hustshawn/agent-master/releases) page as `AgentMaster-<tag>.dmg`, built for Apple silicon. Open the disk image and drag AgentMaster to Applications. The app is ad-hoc signed and not notarized, so run `xattr -dr com.apple.quarantine /Applications/AgentMaster.app` before the first launch. The same release also carries the [web edition](#web-edition) server for Linux x86_64 and aarch64, plus `install-server.sh`.

## Build and run

```bash
./scripts/bundle.sh          # builds build/AgentMaster.app (ad-hoc signed)
open build/AgentMaster.app
```

### Releasing

Pull requests and `main` run `.github/workflows/ci.yml`. It only runs the tests, and only for the side a change can affect. The Mac app is tested on macOS, the server on Linux x86_64, and shared code on both. Docs-only changes run nothing. Builds are cached.

Pushing a tag that starts with `v` runs `.github/workflows/release.yml`. It tests and builds everything with the tag as the version: the Mac app's disk image and static server packages for Linux x86_64 and arm64. Then it creates the GitHub release with those files and `install-server.sh` attached:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

To try the full release build before tagging, run it by hand (Actions → Release → Run workflow). It builds and packages everything and publishes nothing.

## Web edition

`agentmaster-server` runs the same agents on a remote machine (Linux or macOS) and serves the AgentMaster UI to a browser. It has the sidebar, the real agent TUI in the page (xterm.js), the inspector, the new-session panel and Settings. Sessions live on the server, so closing the browser does not stop an agent. Reconnecting shows the terminal again.

### Install on a Linux server

On the server (x86_64 or aarch64), log in as the user who runs `claude` or `codex` and run:

```bash
gh release download -R hustshawn/agent-master -p install-server.sh -O - | bash
```

This downloads the latest release's server package for the machine's architecture. The Swift runtime is linked in, so the server needs no Swift. It installs to `~/.local/share/agentmaster-server` and runs as a systemd user service with lingering on, so it keeps running after you log out and restarts if it crashes. Then it prints the link with the token. No root is needed.

- Run the same command again to upgrade. Sessions, settings and the token in `~/.agentmaster-server` are kept.
- Pass options after `bash -s --`, for example `… | bash -s -- --port 9000`:
  - `--host`, `--port`: where the server listens
  - `--version v0.3.0`: install a specific release
  - `--from FILE`: install from a package you already downloaded
  - `--uninstall`: remove it
- Without `gh`, set `GITHUB_TOKEN` to a token that can read the repo. Fetch the script with `curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github.raw" https://api.github.com/repos/hustshawn/agent-master/contents/scripts/install-server.sh | bash`.
- Manage it with `systemctl --user status|restart|stop agentmaster-server`, and read the logs with `journalctl --user -u agentmaster-server -f`. Where there is no systemd user session, such as a container, it falls back to `nohup`.

It listens on `127.0.0.1` by default. From your machine, `ssh -L 8765:127.0.0.1:8765 you@server` and open the printed link. For access over a network, put it behind your own TLS-terminating proxy or load balancer, and pass `--host 0.0.0.0` if the proxy is on another machine. Anyone with the token can run commands as the server's user.

### Run it yourself

To build from source (Swift 6, on the machine it will run on), or on macOS:

```bash
scripts/package-server.sh                          # → build/agentmaster-server-<os>-<arch>/ and a .tar.gz
build/agentmaster-server-linux-x86_64/agentmaster-server
# AgentMaster server on http://127.0.0.1:8765
# Open: http://127.0.0.1:8765/#token=…
```

| Option | Default | |
|---|---|---|
| `--host` | `127.0.0.1` | Address to listen on |
| `--port` | `8765` | |
| `--data-dir` | `~/.agentmaster-server` | Sessions, `settings.json` and the token. Separate from the Mac app's data, so both can run on one machine |
| `--token` | `AGENTMASTER_SERVER_TOKEN`, else `<data-dir>/token` | The access token. A random one is created on first start |

`agentmaster-hook` must stay next to `agentmaster-server`, and the server must run as a user whose login shell finds the agents. In the browser, Alt+N starts another session with the selected session's agent, and Alt+0 toggles the inspector. Images pasted (⌘V) or dropped into the terminal are uploaded to the session's folder in the data directory, and their path goes to the agent, which attaches them. They are deleted with the session. The design is in [ADR 0011](docs/adr/0011-web-edition.md).

## Development

```bash
swift build
swift test                   # unit and integration tests
python3 scripts/smoke.py     # end-to-end check against the real claude (uses a few cents of Haiku tokens)
uv run --with websockets scripts/web-smoke.py --agent claude   # the same through agentmaster-server's API (or --agent codex, --restart)
uv run --with playwright scripts/web-ui-check.py               # the web UI in headless Chromium against the real claude
swift scripts/make-icon.swift  # regenerate Assets/AppIcon.icns
```

The code is a single SwiftPM package with these targets:

| Target | Role |
|---|---|
| `AgentMasterCore` | Domain models, session state reducer, theme tokens |
| `AgentMasterWire` | NDJSON protocol over a Unix socket, hook shim logic |
| `agentmaster-hook` | Small helper that every agent calls as its hook |
| `AgentMasterBridge` | Agent adapters and registry, hook dialects and translation, launch environment, session restore |
| `TerminalKit` | SwiftTerm wrapper |
| `AgentMasterUI` | Sidebar, inspector, header, new-session panel and settings views |
| `AgentMaster` | The app |
| `CPTY` | Starts an agent in a pseudo-terminal (web edition) |
| `AgentMasterServerKit` | Sessions, HTTP/WebSocket API and the browser UI (web edition) |
| `agentmaster-server` | The web edition's server |

### Adding an agent

Each agent is one file in `Sources/AgentMasterBridge/`. It declares only how its CLI differs:

- where its binary lives
- its settings
- how it loads AgentMaster's hooks
- its other launch arguments
- how its hook payloads read, if they differ from Claude Code's

Finding the binary, the session environment, resuming, the panels, the new-session panel, Settings and the menus are shared. Add the new agent to `AgentRegistry.all` and it shows up everywhere. The checklist, with a comparison of Claude Code, Codex and Kiro CLI, is in [ADR 0010](docs/adr/0010-agent-adapter.md).

## Documentation

- Design: [`docs/superpowers/specs/`](docs/superpowers/specs/)
- Decisions: [`docs/adr/`](docs/adr/)

## Status

This is an early internal tool and is still under active development. The roadmap, in order:

1. A git-based review of changes
2. Subagent results in the inspector
3. Native approval and question prompts

## License

Copyright (c) 2026 Shawn Zhang. All rights reserved. The code is proprietary: using, copying or distributing it needs the copyright holder's written permission. Third-party components keep their own licenses. See [LICENSE](LICENSE).
