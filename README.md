<p align="center">
  <img src="Assets/AppIcon-1024.png" width="128" alt="AgentMaster icon">
</p>

# AgentMaster

A native macOS shell for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview).

AgentMaster runs the real Claude Code TUI in an embedded terminal and wraps it in a native UI. It adds a session sidebar across projects, live panels for the current session, and per-agent defaults. It does not reimplement the agent. Claude Code keeps working exactly as it does in your terminal, including `CLAUDE.md`, skills, MCP servers, hooks and plugins.

## Features

- **Multiple sessions, grouped by project.** Start sessions from recent folders. Each session is titled by its first prompt, and you can rename it.
- **Restore on launch.** Sessions that were open when you quit come back with `claude --resume`.
- **Review inspector.** A collapsible side panel (⌥⌘0) shows todos, subagents and file changes for the selected session.
- **Header status.** The model, permission mode, context usage and cost are always visible.
- **Per-agent settings (⌘,).** Set the default model, permission mode and whether bypass is allowed for new sessions.
- **Codex CLI too.** Every ＋ opens a panel where you pick Claude Code or [OpenAI Codex](https://github.com/openai/codex) and, optionally, a model other than the agent's default; ⌥⌘N starts Codex directly. Its panels and restore work through Codex hooks, which AgentMaster runs with `--dangerously-bypass-hook-trust`; turn that off in Settings to run Codex without hooks.
- **Non-invasive integration.** Hooks are injected per session through `--settings`. Your global Claude Code configuration is never modified. If AgentMaster isn't running, Claude Code falls back to its normal behaviour.

## Requirements

- macOS 14 or later
- Xcode 15.4 (Swift 5.10) or later
- Claude Code installed at `~/.local/bin/claude`, or anywhere on your login shell's `PATH`. To point at a different binary, set `AGENTMASTER_CLAUDE_PATH`.
- Optional: Codex CLI 0.154 or later, found the same way (`~/.local/bin/codex`, `PATH`, or `AGENTMASTER_CODEX_PATH`).

## Build and run

```bash
./scripts/bundle.sh          # builds build/AgentMaster.app (ad-hoc signed)
open build/AgentMaster.app
```

## Development

```bash
swift build
swift test                   # unit and integration tests
python3 scripts/smoke.py     # end-to-end check against the real claude (uses a few cents of Haiku tokens)
swift scripts/make-icon.swift  # regenerate Assets/AppIcon.icns
```

The code is a single SwiftPM package with these targets:

| Target | Role |
|---|---|
| `AgentMasterCore` | Domain models, session state reducer, theme tokens |
| `AgentMasterWire` | NDJSON protocol over a Unix socket, hook shim logic |
| `agentmaster-hook` | Small helper that Claude Code calls as a hook |
| `AgentMasterBridge` | Agent abstraction, hook translation, launch environment, session restore |
| `TerminalKit` | SwiftTerm wrapper |
| `AgentMasterUI` | Sidebar, inspector and header views |
| `AgentMaster` | The app |

## Documentation

- Design: [`docs/superpowers/specs/`](docs/superpowers/specs/)
- Decisions: [`docs/adr/`](docs/adr/)

## Status

This is an early internal tool and is still under active development. The roadmap, in order:

1. A git-based review of changes
2. Subagent results in the inspector
3. Native approval and question prompts
