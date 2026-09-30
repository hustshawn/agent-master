#!/bin/bash
# Installs (or upgrades) agentmaster-server on this Linux machine and keeps it running as a systemd user service.
#
#   gh release download -R hustshawn/agent-master -p install-server.sh -O - | bash
#   gh release download -R hustshawn/agent-master -p install-server.sh -O - | bash -s -- --port 9000
#
# Options:
#   --version TAG    install this release (default: the latest)
#   --from FILE      install from a local agentmaster-server-*-linux-<arch>.tar.gz instead of downloading
#   --host ADDR      address to listen on (default 127.0.0.1)
#   --port PORT      port (default 8765)
#   --uninstall      stop and remove the service and the installed files (keeps ~/.agentmaster-server)
#
# Downloads use `gh` when it is installed and logged in, else GITHUB_TOKEN with the GitHub API (the repo is
# private). Nothing here needs root. Sessions, settings and the token live in ~/.agentmaster-server and survive
# upgrades. Run it as the user whose login shell finds `claude`, `codex` and `kiro-cli`.
set -euo pipefail

REPO="${AGENTMASTER_REPO:-hustshawn/agent-master}"
VERSION=""
FROM=""
HOST="127.0.0.1"
PORT="8765"
UNINSTALL=false
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help) sed -n '2,17p' "$0" 2>/dev/null || true; exit 0 ;;
        *) echo "install-server.sh: unknown option $1" >&2; exit 2 ;;
    esac
done

PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/agentmaster-server"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="agentmaster-server.service"
DATA="$HOME/.agentmaster-server"
say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'install-server.sh: %s\n' "$*" >&2; exit 1; }

# The API URL of the release asset whose name ends in $2, from the release JSON in $1. Each asset's "url" is
# followed by its "name"; the release's own "name" comes before the assets, so it pairs with nothing.
asset_url() {
    grep -o '"url": *"[^"]*/releases/assets/[0-9]*"\|"name": *"[^"]*"' "$1" | awk -v suffix="$2\"" '
        /\/releases\/assets\// { split($0, part, "\""); url = part[4]; next }
        url != "" { if (substr($0, length($0) - length(suffix) + 1) == suffix) { print url; exit } url = "" }'
}

has_systemd() {
    command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1
}

stop_running() {
    if has_systemd && systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
        systemctl --user stop "$UNIT"
    elif [ -f "$PREFIX/server.pid" ] && kill -0 "$(cat "$PREFIX/server.pid")" 2>/dev/null; then
        kill "$(cat "$PREFIX/server.pid")"; sleep 2
    fi
}

if $UNINSTALL; then
    stop_running
    if has_systemd; then
        systemctl --user disable "$UNIT" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$UNIT"
        systemctl --user daemon-reload
    fi
    rm -rf "$PREFIX"
    say "Removed agentmaster-server. Your sessions, settings and token are still in $DATA."
    exit 0
fi

[ "$(uname -s)" = Linux ] || die "this installs the Linux build; on a Mac run scripts/package-server.sh instead."
case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) die "no build for $(uname -m); build one with scripts/package-server.sh." ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. The package for this architecture.
if [ -n "$FROM" ]; then
    [ -f "$FROM" ] || die "$FROM does not exist."
    cp "$FROM" "$WORK/server.tar.gz"
    [ -n "$VERSION" ] || VERSION="$(basename "$FROM" | sed -n 's/^agentmaster-server-\(v[^-]*\)-linux-.*/\1/p')"
    VERSION="${VERSION:-local}"
else
    PATTERN="agentmaster-server-*-linux-$ARCH.tar.gz"
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        [ -n "$VERSION" ] || VERSION="$(gh release view -R "$REPO" --json tagName -q .tagName)"
        say "Downloading $VERSION for linux-$ARCH with gh"
        gh release download "$VERSION" -R "$REPO" -p "$PATTERN" -D "$WORK" --clobber
        mv "$WORK"/agentmaster-server-*.tar.gz "$WORK/server.tar.gz"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        command -v curl >/dev/null || die "curl is needed to download with GITHUB_TOKEN."
        API="https://api.github.com/repos/$REPO/releases/${VERSION:+tags/$VERSION}"
        [ -n "$VERSION" ] || API="${API}latest"
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$API" -o "$WORK/release.json"
        VERSION="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$WORK/release.json" | head -1)"
        ASSET="$(asset_url "$WORK/release.json" "linux-$ARCH.tar.gz")"
        [ -n "$ASSET" ] || die "release $VERSION has no linux-$ARCH package."
        say "Downloading $VERSION for linux-$ARCH with GITHUB_TOKEN"
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/octet-stream" "$ASSET" -o "$WORK/server.tar.gz"
    else
        die "log in with 'gh auth login', set GITHUB_TOKEN, or pass --from with a downloaded package."
    fi
fi

# 2. Unpack next to earlier versions and switch 'current' over.
TARGET="$PREFIX/$VERSION"
rm -rf "$TARGET" && mkdir -p "$TARGET"
tar -xzf "$WORK/server.tar.gz" -C "$TARGET" --strip-components 1
[ -x "$TARGET/agentmaster-server" ] && [ -x "$TARGET/agentmaster-hook" ] || die "the package is missing its binaries."
stop_running
ln -sfn "$TARGET" "$PREFIX/current"
find "$PREFIX" -mindepth 1 -maxdepth 1 -type d ! -name "$VERSION" -exec rm -rf {} +   # keep only this version

# The agents come from the login shell the server captures at startup; warn early if they are not there.
for agent in claude codex kiro-cli; do
    if ! "${SHELL:-/bin/bash}" -lic "command -v $agent" >/dev/null 2>&1; then
        echo "note: '$agent' is not on your login shell's PATH; its sessions will not start." >&2
    fi
done

# 3. Keep it running.
EXEC="$PREFIX/current/agentmaster-server --host $HOST --port $PORT"
if has_systemd; then
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=AgentMaster server (web edition)
After=network-online.target

[Service]
ExecStart=$EXEC
Restart=on-failure
RestartSec=3
# The agents' own processes are the session's; stopping the service ends them too.
KillMode=control-group

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT" >/dev/null
    # Without lingering, the user's services stop when the last SSH session closes.
    if command -v loginctl >/dev/null && [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
        loginctl enable-linger "$USER" 2>/dev/null ||
            echo "note: run 'sudo loginctl enable-linger $USER' so the server keeps running after you log out." >&2
    fi
    HOW="systemctl --user {status|restart|stop} $UNIT   ·   logs: journalctl --user -u $UNIT -f"
else
    say "No systemd user session here; starting it in the background with nohup instead."
    nohup $EXEC > "$PREFIX/server.log" 2>&1 &
    echo $! > "$PREFIX/server.pid"
    HOW="log: $PREFIX/server.log   ·   stop: kill \$(cat $PREFIX/server.pid)   ·   rerun this script after a reboot"
fi

# 4. Where to find it, once it answers (the token file alone may be left from an earlier version).
PROBE="$HOST"; [ "$HOST" = 0.0.0.0 ] && PROBE=127.0.0.1
up=false
for _ in $(seq 1 75); do
    if (exec 3<>"/dev/tcp/$PROBE/$PORT") 2>/dev/null; then up=true; break; fi
    sleep 0.2
done
$up && [ -s "$DATA/token" ] || die "the server did not start on $HOST:$PORT ($HOW)."
SHOWN="$HOST"; [ "$HOST" = 0.0.0.0 ] && SHOWN="<this-host>"
cat <<EOF

AgentMaster server $VERSION is running on $HOST:$PORT.

  Open:  http://$SHOWN:$PORT/#token=$(cat "$DATA/token")
  From your machine through SSH:  ssh -L $PORT:127.0.0.1:$PORT $USER@$(hostname)
  $HOW
  Upgrade: run this installer again. Remove: add --uninstall.
EOF
