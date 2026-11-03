# Contributing to AgentMaster

How to build, test and release AgentMaster, and how the code is laid out. Installing and using it is in the [README](README.md).

## Requirements

- The Mac app: macOS 14 or later and Xcode 15.4 (Swift 5.10) or later. Xcode 26 and later download the Metal toolchain separately; if the build fails with "missing Metal Toolchain" (SwiftTerm has a Metal shader), run `xcodebuild -downloadComponent MetalToolchain` once.
- The web edition's server on Linux: Swift 6.
- At least one [supported agent](README.md#requirements) to try a change against.

## Build and run

The Mac app:

```bash
./scripts/bundle.sh          # builds build/AgentMaster.app (ad-hoc signed)
open build/AgentMaster.app
```

The web edition's server, built from source on the machine it will run on, or on macOS:

```bash
scripts/package-server.sh                          # → build/agentmaster-server-<os>-<arch>/ and a .tar.gz
build/agentmaster-server-linux-x86_64/agentmaster-server
# AgentMaster server on http://127.0.0.1:8765
# Open: http://127.0.0.1:8765/#token=…
```

Its options are in the README's [Server options](README.md#server-options).

## Development

```bash
swift build
swift test                   # unit and integration tests
python3 scripts/smoke.py     # end-to-end check against the real claude (uses a few cents of Haiku tokens)
uv run --with websockets scripts/web-smoke.py --agent claude   # the same through agentmaster-server's API (or --agent codex|kiro, --restart)
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

## Releasing

Pull requests and `main` run `.github/workflows/ci.yml`. It runs the tests, and only for the side a change can affect. The Mac app is tested on macOS, the server on Linux x86_64, and shared code on both. Docs-only changes run nothing. Builds are cached. A change to how a side is packaged (`Package.swift`, `Package.resolved`, `scripts/bundle.sh`, `scripts/make-dmg.sh`, `scripts/package-server.sh` or `release.yml`) also runs that side's packaging scripts after its tests, so a release that would fail to build fails in CI first. Nothing is uploaded.

Pushing a tag that starts with `v` runs `.github/workflows/release.yml`. It builds everything with the tag as the version: the Mac app's disk image and static server packages for Linux x86_64 and arm64. Then it creates the GitHub release with those files and `install-server.sh` attached. It does not repeat tests CI already passed on the tagged commit: the app skips them when CI's macOS job passed on it, the x86_64 server when CI's Linux job did. The arm64 server, which CI does not cover, always runs them, and so does a side CI skipped or has not finished. Tag a commit after its CI has passed:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

To try the full release build before tagging, run it by hand (Actions → Release → Run workflow). It builds and packages everything and publishes nothing.

## Documentation

- Design: [`docs/superpowers/specs/`](docs/superpowers/specs/)
- Decisions: [`docs/adr/`](docs/adr/)
