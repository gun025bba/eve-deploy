#!/bin/bash
# Needs sudo (once): installs the root-owned job-started hook and points both eve-host runners at it, then restarts them.
#   sudo bash host/guard-install.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
install -d -o root -g wheel -m 755 /opt/eve-runner/guard
install -o root -g wheel -m 755 "$here/eve-host-guard.sh" /opt/eve-runner/guard/job-started.sh
for d in /opt/eve-runner/eve-serving /opt/eve-runner/eve-web; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  grep -q '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' "$d/.env" 2>/dev/null || echo 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/eve-runner/guard/job-started.sh' >>"$d/.env"
  launchctl kickstart -k "system/com.eve.runner.$name" || true
  echo "$name: guarded"
done
