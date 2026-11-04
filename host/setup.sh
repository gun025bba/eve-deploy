#!/bin/bash
# One-time host setup for tag-driven deploys. Run ONCE by an admin:   sudo bash host/setup.sh
# Everything after this is automatic: a merge into main -> GitHub Actions -> this host's runner -> bin/deploy.
#
# What it does (nothing else; it does not touch config, data, secrets or the existing gateway service):
#   1. makes the runner account own only the code directories under /opt/eve-gw (bin, web, previous, state)
#   2. installs the restart watcher (root-owned): lets the non-admin runner account restart exactly one service without sudo
#   3. installs one self-hosted runner per repo (label "eve-host"), running as the non-admin account, outbound HTTPS only
#
# Runner registration tokens come from GitHub (repo -> Settings -> Actions -> Runners -> New self-hosted runner), valid 1 hour.
# They are read from the terminal (or from RUNNER_TOKEN_EVE_SERVING / RUNNER_TOKEN_EVE_WEB) and never written to disk.
set -euo pipefail

EVE_ROOT=${EVE_ROOT:-/opt/eve-gw}
RUNNER_USER=${RUNNER_USER:-evedeploy}
OWNER=${EVE_OWNER:-gun025bba}
RUNNER_VERSION=2.338.2
RUNNER_ASSET=actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz
RUNNER_SHA256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388   # pinned: the download is refused if it differs
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo bash host/setup.sh" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "this script is for the macOS host" >&2; exit 1; }
id "$RUNNER_USER" >/dev/null 2>&1 || { echo "account $RUNNER_USER does not exist" >&2; exit 1; }
if dscl . -read /Groups/admin GroupMembership 2>/dev/null | tr ' ' '\n' | grep -qx "$RUNNER_USER"; then
  echo "refusing: $RUNNER_USER is an admin account. The runner must not be admin." >&2; exit 1
fi

echo "== 1/3 code directories owned by $RUNNER_USER"
for d in bin web previous state; do mkdir -p "$EVE_ROOT/$d"; chown -R "$RUNNER_USER" "$EVE_ROOT/$d"; chmod -R go+rX "$EVE_ROOT/$d"; done
: >"$EVE_ROOT/restart.trigger"; chown "$RUNNER_USER" "$EVE_ROOT/restart.trigger"; chmod 644 "$EVE_ROOT/restart.trigger"

echo "== 2/3 restart watcher"
mkdir -p /usr/local/libexec /var/db/eve-restart && chmod 755 /var/db/eve-restart
install -o root -g wheel -m 755 "$HERE/restart-watcher.sh" /usr/local/libexec/eve-restart-watcher
sed "s#__EVE_ROOT__#$EVE_ROOT#g" "$HERE/restart-watcher.plist.template" >/Library/LaunchDaemons/com.eve.restart-watcher.plist
chown root:wheel /Library/LaunchDaemons/com.eve.restart-watcher.plist; chmod 644 /Library/LaunchDaemons/com.eve.restart-watcher.plist
launchctl bootout system/com.eve.restart-watcher 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.eve.restart-watcher.plist

echo "== gateway: migrations on startup (GW_DB_AUTO_MIGRATE=true)"
# BE decision (C5): the gateway applies its own forward-only migrations at start; the deploy step never touches the database.
# Only this one key of the live plist is changed (a backup is kept next to it); nothing is printed from the plist. It takes effect at the next restart = the next deploy.
GW_PLIST=${GW_PLIST:-/Library/LaunchDaemons/com.llmserving.gateway.plist}
PB=/usr/libexec/PlistBuddy
if [ -f "$GW_PLIST" ]; then
  if [ "$("$PB" -c 'Print :EnvironmentVariables:GW_DB_AUTO_MIGRATE' "$GW_PLIST" 2>/dev/null || true)" = true ]; then
    echo "  already true"
  else
    cp -p "$GW_PLIST" "$GW_PLIST.pre-eve-deploy" && chmod 600 "$GW_PLIST.pre-eve-deploy"
    "$PB" -c 'Print :EnvironmentVariables' "$GW_PLIST" >/dev/null 2>&1 || "$PB" -c 'Add :EnvironmentVariables dict' "$GW_PLIST"
    "$PB" -c 'Set :EnvironmentVariables:GW_DB_AUTO_MIGRATE true' "$GW_PLIST" >/dev/null 2>&1 || "$PB" -c 'Add :EnvironmentVariables:GW_DB_AUTO_MIGRATE string true' "$GW_PLIST"
    plutil -lint "$GW_PLIST" >/dev/null || { echo "plist is not valid after the change; restoring the backup" >&2; cp -p "$GW_PLIST.pre-eve-deploy" "$GW_PLIST"; exit 1; }
    echo "  set to true (backup: $GW_PLIST.pre-eve-deploy); active at the next gateway restart"
  fi
else
  echo "  $GW_PLIST not found: set GW_DB_AUTO_MIGRATE=true in the gateway's launchd environment yourself (or re-run with GW_PLIST=<path>)"
fi

echo "== 3/3 self-hosted runners"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 5 -o "$TMP/$RUNNER_ASSET" "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/$RUNNER_ASSET"
[ "$(shasum -a 256 "$TMP/$RUNNER_ASSET" | awk '{print $1}')" = "$RUNNER_SHA256" ] || { echo "runner download does not match the pinned sha256; stopping" >&2; exit 1; }

install_runner() { # $1 repo $2 token-env-name
  local repo=$1 name dir token
  name=$(echo "$repo" | tr 'A-Z_' 'a-z-'); dir=/opt/eve-runner/$name
  if [ -f "$dir/.runner" ]; then echo "  $repo: runner already configured, skipping"; return 0; fi
  token=${!2:-}
  if [ -z "$token" ]; then printf '  registration token for %s/%s (input hidden, Enter to skip): ' "$OWNER" "$repo"; read -rs token; echo; fi
  [ -n "$token" ] || { echo "  $repo: skipped"; return 0; }
  mkdir -p "$dir" && tar -xzf "$TMP/$RUNNER_ASSET" -C "$dir" && chown -R "$RUNNER_USER" "$dir"
  sudo -u "$RUNNER_USER" -H bash -c 'cd "$1" && ./config.sh --unattended --url "$2" --token "$3" --name "$4" --labels eve-host --work _work --replace' _ \
    "$dir" "https://github.com/$OWNER/$repo" "$token" "eve-host-$name"
  token=""
  sed -e "s#__NAME__#$name#g" -e "s#__RUNNER_USER__#$RUNNER_USER#g" -e "s#__RUNNER_DIR__#$dir#g" "$HERE/runner.plist.template" >"/Library/LaunchDaemons/com.eve.runner.$name.plist"
  chown root:wheel "/Library/LaunchDaemons/com.eve.runner.$name.plist"; chmod 644 "/Library/LaunchDaemons/com.eve.runner.$name.plist"
  launchctl bootout "system/com.eve.runner.$name" 2>/dev/null || true
  launchctl bootstrap system "/Library/LaunchDaemons/com.eve.runner.$name.plist"
  echo "  $repo: runner installed"
}
install_runner eve-serving RUNNER_TOKEN_EVE_SERVING
install_runner eve-web RUNNER_TOKEN_EVE_WEB

echo
echo "Done. Check: GitHub -> each repo -> Settings -> Actions -> Runners shows 'eve-host' Idle."
echo "Nothing deploys yet: the workflows stay off until the repo variable AUTO_RELEASE is set to 'on' (see README)."
