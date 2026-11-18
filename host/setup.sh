#!/bin/bash
# One-time host setup for tag-driven deploys. Run ONCE by an admin:
#   sudo EVE_RUN_USER=<login-account> bash host/setup.sh
# EVE_RUN_USER is required. The script exits with a clear error when it is unset.
# It refuses a missing account, an admin account, root, and any account whose uid is 0.
#   EVE_RUN_USER=<login-account> bash host/setup.sh --check-run-user
# checks the account and does nothing else. The cutover one-liner uses that.
# Everything after this is automatic: a merge into main -> GitHub Actions -> this host's runner -> bin/deploy.
#
# What it does (nothing else; it does not touch config, data, secrets or a running supervisor):
#   1. makes the runner account own the code directories under /opt/eve-gw, plus the supervisor release root and socket directory
#   2. installs one self-hosted runner per repo (label "eve-host"), running as the non-admin account, outbound HTTPS only
#
# Runner registration tokens come from GitHub (repo -> Settings -> Actions -> Runners -> New self-hosted runner), valid 1 hour.
# They are read from the terminal (or from RUNNER_TOKEN_EVE_SERVING / RUNNER_TOKEN_EVE_WEB) and never written to disk.
set -euo pipefail

eve_check_run_user() { # $1 account. Exists, is not admin, and is not root or uid 0.
  local user=${1:-}
  if [ -z "$user" ]; then
    echo "EVE_RUN_USER is required: set it to the login account that owns the deploy directories and the runner." >&2
    return 1
  fi
  if ! id "$user" >/dev/null 2>&1; then
    echo "account $user does not exist" >&2
    return 1
  fi
  if [ "$user" = root ] || [ "$(id -u "$user")" = 0 ]; then
    echo "refusing: $user is root (uid 0). The runner must not be root." >&2
    return 1
  fi
  if dscl . -read /Groups/admin GroupMembership 2>/dev/null | tr ' ' '\n' | grep -qx "$user"; then
    echo "refusing: $user is an admin account. The runner must not be admin." >&2
    return 1
  fi
  return 0
}

if [ "${1:-}" = --check-run-user ]; then
  eve_check_run_user "${EVE_RUN_USER:-}" || exit 1
  exit 0
fi

EVE_ROOT=${EVE_ROOT:-/opt/eve-gw}
eve_check_run_user "${EVE_RUN_USER:-}" || exit 1
RUNNER_USER=$EVE_RUN_USER
OWNER=${EVE_OWNER:-gun025bba}
RUNNER_VERSION=2.338.2
RUNNER_ASSET=actions-runner-osx-arm64-$RUNNER_VERSION.tar.gz
RUNNER_SHA256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388   # pinned: the download is refused if it differs
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo EVE_RUN_USER=<login-account> bash host/setup.sh" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "this script is for the macOS host" >&2; exit 1; }

echo "== 1/2 code directories owned by $RUNNER_USER"
for d in bin web previous state; do mkdir -p "$EVE_ROOT/$d"; chown -R "$RUNNER_USER" "$EVE_ROOT/$d"; chmod -R go+rX "$EVE_ROOT/$d"; done
# release_root and the control-socket directory. 0700: the supervisor refuses a socket directory that is not private.
install -d -o "$RUNNER_USER" -m 0700 "$EVE_ROOT/deploy" "$EVE_ROOT/run"
chown "$RUNNER_USER" "$EVE_ROOT/deploy" "$EVE_ROOT/run"
chmod 700 "$EVE_ROOT/deploy" "$EVE_ROOT/run"

echo "== 2/2 self-hosted runners"
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
