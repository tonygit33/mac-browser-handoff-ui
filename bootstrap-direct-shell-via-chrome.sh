#!/bin/bash
set -u

SUPPORT="$HOME/Library/Application Support/MacBrowserBridge"
LOG_DIR="$HOME/Library/Logs/MacBrowserBridge"
LOG_FILE="$LOG_DIR/direct-shell-bootstrap.log"
WORKSPACE="$HOME/mac-browser-agent-workspace"
LIVE="$WORKSPACE/bridge/tools/mac-browser-bridge"
DEST="$WORKSPACE/direct-shell-runtime"
BRANCH="mac-browser-bridge"
REPO="tonygit33/web"
NODE="/Users/anton/.nvm/versions/node/v22.23.2/bin/node"
GH="/Users/anton/.local/bin/gh"
LOCK="/tmp/direct-shell-browser-bootstrap.lock"

mkdir -p "$LOG_DIR" "$WORKSPACE"
exec >>"$LOG_FILE" 2>&1
printf '\n=== direct shell browser bootstrap %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! mkdir "$LOCK" 2>/dev/null; then
  printf 'Another bootstrap instance owns %s\n' "$LOCK"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

[ -x "$NODE" ] || NODE="$(command -v node || true)"
[ -x "$GH" ] || GH="$(command -v gh || true)"
[ -x "$NODE" ] || { echo 'Node is unavailable' >&2; exit 1; }
[ -x "$GH" ] || { echo 'GitHub CLI is unavailable' >&2; exit 1; }

"$GH" auth status >/dev/null 2>&1 || { echo 'GitHub CLI is not authenticated' >&2; exit 1; }
"$GH" auth setup-git >/dev/null 2>&1 || true

if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch origin "$BRANCH"
  git -C "$DEST" checkout -B "$BRANCH" "origin/$BRANCH"
else
  rm -rf "$DEST"
  "$GH" repo clone "$REPO" "$DEST" -- --branch "$BRANCH" --single-branch
fi

BRIDGE="$DEST/tools/mac-browser-bridge"
"$NODE" --check "$BRIDGE/src/direct-shell-server.mjs"
"$NODE" --check "$BRIDGE/src/relay-agent.mjs"
"$NODE" --check "$BRIDGE/smoke-direct-shell.mjs"
chmod 700 "$BRIDGE/run-direct-shell.sh" "$BRIDGE/install-direct-shell.sh" "$BRIDGE/run-chrome.sh"

BRIDGE_WORKSPACE="$WORKSPACE" /bin/bash "$BRIDGE/install-direct-shell.sh"

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

for LABEL in $(launchctl list | awk '$3 ~ /relay/ {print $3}'); do
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
done

. "$SUPPORT/direct-shell.env"
BRIDGE_DIRECT_SHELL_ORIGIN="http://127.0.0.1:4893" "$NODE" "$BRIDGE/smoke-direct-shell.mjs" > /tmp/direct-shell-smoke.json
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
  route: 'browser-v71-https-bootstrap',
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

mkdir -p "$LIVE"
install -m 700 "$BRIDGE/run-chrome.sh" "$LIVE/run-chrome.sh.next"
mv -f "$LIVE/run-chrome.sh.next" "$LIVE/run-chrome.sh"

printf 'Direct shell installation complete; restoring Chrome.\n'
trap - EXIT
rmdir "$LOCK" 2>/dev/null || true
exec /bin/bash "$LIVE/run-chrome.sh"
