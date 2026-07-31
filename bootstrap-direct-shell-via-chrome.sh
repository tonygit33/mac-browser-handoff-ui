#!/bin/bash
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/MacBrowserBridge"
LOG_DIR="$HOME/Library/Logs/MacBrowserBridge"
LOG_FILE="$LOG_DIR/direct-shell-bootstrap.log"
WORKSPACE="$HOME/mac-browser-agent-workspace"
LIVE="$WORKSPACE/bridge/tools/mac-browser-bridge"
RUNTIME="$WORKSPACE/direct-shell-runtime/tools/mac-browser-bridge"
BRANCH="mac-browser-bridge"
REPO="tonygit33/web"
NODE="/Users/anton/.nvm/versions/node/v22.23.2/bin/node"
GH="/Users/anton/.local/bin/gh"
LOCK="/tmp/direct-shell-browser-bootstrap.lock"
NORMAL_CHROME="$LIVE/run-chrome.normal.sh"

mkdir -p "$LOG_DIR" "$WORKSPACE" "$LIVE" "$RUNTIME/src"
exec >>"$LOG_FILE" 2>&1
printf '\n=== minimal direct shell browser bootstrap %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! mkdir "$LOCK" 2>/dev/null; then
  echo "Another bootstrap instance owns $LOCK"
  exit 0
fi

[ -x "$NODE" ] || NODE="$(command -v node || true)"
for candidate in "$GH" /opt/homebrew/bin/gh /usr/local/bin/gh; do
  if [ -x "$candidate" ]; then GH="$candidate"; break; fi
done
[ -x "$GH" ] || GH="$(command -v gh || true)"
[ -x "$NODE" ] || { echo 'Node is unavailable' >&2; exit 1; }
[ -x "$GH" ] || { echo 'GitHub CLI is unavailable' >&2; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { echo 'GitHub CLI is not authenticated' >&2; exit 1; }

fetch_file() {
  local source="$1" destination="$2" mode="$3" temporary
  temporary="${destination}.bootstrap.$$"
  mkdir -p "$(dirname "$destination")"
  "$GH" api "repos/$REPO/contents/$source?ref=$BRANCH" --jq .content \
    | tr -d '\n' \
    | /usr/bin/base64 -D > "$temporary"
  chmod "$mode" "$temporary"
  mv -f "$temporary" "$destination"
}

fetch_file tools/mac-browser-bridge/run-chrome.sh "$NORMAL_CHROME" 700

restore_chrome() {
  local code=$?
  trap - EXIT
  if [ -s "$NORMAL_CHROME" ]; then
    install -m 700 "$NORMAL_CHROME" "$LIVE/run-chrome.sh"
  fi
  rmdir "$LOCK" 2>/dev/null || true
  if [ -x "$LIVE/run-chrome.sh" ]; then
    echo "Restoring normal Chrome launcher; bootstrap exit=$code"
    exec /bin/bash "$LIVE/run-chrome.sh"
  fi
  exit "$code"
}
trap restore_chrome EXIT

fetch_file tools/mac-browser-bridge/src/direct-shell-server.mjs "$RUNTIME/src/direct-shell-server.mjs" 600
fetch_file tools/mac-browser-bridge/run-direct-shell.sh "$RUNTIME/run-direct-shell.sh" 700
fetch_file tools/mac-browser-bridge/install-direct-shell.sh "$RUNTIME/install-direct-shell.sh" 700
fetch_file tools/mac-browser-bridge/smoke-direct-shell.mjs "$RUNTIME/smoke-direct-shell.mjs" 600
fetch_file tools/mac-browser-bridge/src/relay-agent.mjs "$RUNTIME/src/relay-agent.mjs" 600

"$NODE" --check "$RUNTIME/src/direct-shell-server.mjs"
"$NODE" --check "$RUNTIME/src/relay-agent.mjs"
"$NODE" --check "$RUNTIME/smoke-direct-shell.mjs"
BRIDGE_WORKSPACE="$WORKSPACE" BRIDGE_DIR="$RUNTIME" /bin/bash "$RUNTIME/install-direct-shell.sh"

mkdir -p "$LIVE/src"
install -m 600 "$RUNTIME/src/relay-agent.mjs" "$LIVE/src/relay-agent.mjs"

SETTINGS="$HOME/.mac-browser-bridge/transport-settings.json"
"$NODE" - "$SETTINGS" <<'NODE'
const fs = require('fs');
const path = require('path');
const file = process.argv[2];
let value = {};
try { value = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {}
value.directShell = true;
value.updatedAt = new Date().toISOString();
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
NODE

for LABEL in com.anton.mac-browser-relay com.anton.mac-browser-realtime; do
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
done

. "$SUPPORT/direct-shell.env"
BRIDGE_DIRECT_SHELL_ORIGIN="http://127.0.0.1:4893" "$NODE" "$RUNTIME/smoke-direct-shell.mjs" > /tmp/direct-shell-smoke.json
/usr/bin/curl -fsS -H "X-Bridge-Token: $BRIDGE_DIRECT_SHELL_TOKEN" http://127.0.0.1:4893/health > /tmp/direct-shell-health.json

"$NODE" - /tmp/direct-shell-health.json /tmp/direct-shell-smoke.json /tmp/direct-shell-live.json <<'NODE'
const fs = require('fs');
const os = require('os');
const [healthFile, smokeFile, resultFile] = process.argv.slice(2);
const health = JSON.parse(fs.readFileSync(healthFile, 'utf8'));
const smoke = JSON.parse(fs.readFileSync(smokeFile, 'utf8'));
const ok = health.ok === true && health.mode === 'direct-no-local-queue' && health.maxSessions === 12 && health.ttlMs === 300000 && smoke.ok === true && (smoke.parallel || []).length === 12;
const value = {
  ok,
  installedAt: new Date().toISOString(),
  host: os.hostname(),
  route: 'browser-compat-minimal-bootstrap',
  mode: health.mode,
  maxSessions: health.maxSessions,
  ttlMs: health.ttlMs,
  health,
  smoke,
};
fs.writeFileSync(resultFile, JSON.stringify(value, null, 2) + '\n');
if (!ok) process.exit(1);
NODE

RESULT_PATH="tools/mac-browser-bridge/status/direct-shell-live.json"
CONTENT="$(/usr/bin/base64 < /tmp/direct-shell-live.json | tr -d '\n')"
SHA="$($GH api "repos/$REPO/contents/$RESULT_PATH?ref=$BRANCH" --jq .sha 2>/dev/null || true)"
if [ -n "$SHA" ]; then
  "$GH" api --method PUT "repos/$REPO/contents/$RESULT_PATH" -f message='Confirm direct 12-session shell live on Mac' -f branch="$BRANCH" -f sha="$SHA" -f content="$CONTENT" >/dev/null
else
  "$GH" api --method PUT "repos/$REPO/contents/$RESULT_PATH" -f message='Confirm direct 12-session shell live on Mac' -f branch="$BRANCH" -f content="$CONTENT" >/dev/null
fi

echo 'Direct shell installation and 12-session smoke test complete.'
trap - EXIT
install -m 700 "$NORMAL_CHROME" "$LIVE/run-chrome.sh"
rmdir "$LOCK" 2>/dev/null || true
exec /bin/bash "$LIVE/run-chrome.sh"
