#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="io.github.ripley-xl.ssh-image-paste-daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$ROOT/.build/release/ssh-image-paste-daemon"
REMOTE_HELPER="~/.local/bin/ssh-clipboard-image-remote.py"

if [[ $# -gt 0 && "$1" != --* ]]; then
  REMOTE_HELPER="$1"
  shift
fi

DAEMON_ARGS=("--remote-helper" "$REMOTE_HELPER" "$@")

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

cd "$ROOT"
swift build -c release

mkdir -p "$HOME/Library/LaunchAgents"
{
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
	  <key>ProgramArguments</key>
	  <array>
	    <string>$BIN</string>
PLIST
for arg in "${DAEMON_ARGS[@]}"; do
  printf '    <string>%s</string>\n' "$(xml_escape "$arg")"
done
cat <<PLIST
	  </array>
	  <key>RunAtLoad</key>
	  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/$LABEL.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/$LABEL.err.log</string>
</dict>
</plist>
PLIST
} > "$PLIST"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed $LABEL"
echo "$PLIST"
