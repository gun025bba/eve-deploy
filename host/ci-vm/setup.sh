#!/bin/bash
# Installs the CI VM + runner supervisor for the CURRENT user (no sudo): colima profile, image, two launchd user agents.
# Run once; safe to re-run. Registration is separate: register.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/ci-env.sh"
for b in colima docker; do command -v $b >/dev/null || { echo "missing $b (brew install colima docker)"; exit 1; }; done
mkdir -p "$CI_HOME/empty" "$HOME/.colima/$CI_PROFILE" "$HOME/Library/LaunchAgents" "$CI_HOME/log"
chmod 755 "$CI_HOME/empty"
if [ ! -f "$HOME/.colima/$CI_PROFILE/colima.yaml" ]; then
  sed "s#__EMPTY_DIR__#$CI_HOME/empty#" "$here/colima-eveci.yaml" >"$HOME/.colima/$CI_PROFILE/colima.yaml"
fi
for s in ci-env.sh vm-up.sh supervisor.sh register.sh setup.sh; do [ "$here" = "$CI_HOME" ] || cp "$here/$s" "$CI_HOME/$s"; done
chmod +x "$CI_HOME"/*.sh
plist() { # $1 label $2 script
  cat >"$HOME/Library/LaunchAgents/$1.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$1</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$CI_HOME/$2</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>30</integer>
<key>StandardOutPath</key><string>$CI_HOME/log/$1.log</string><key>StandardErrorPath</key><string>$CI_HOME/log/$1.log</string>
</dict></plist>
P
}
plist com.eve.ci-vm vm-up.sh
if ! launchctl print "gui/$(id -u)/com.eve.ci-vm" >/dev/null 2>&1; then launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.eve.ci-vm.plist"; fi
echo "waiting for the VM..."; for _ in $(seq 1 90); do docker info >/dev/null 2>&1 && break; sleep 5; done
docker info >/dev/null 2>&1 || { echo "VM did not come up: see $CI_HOME/log/com.eve.ci-vm.log"; exit 1; }
docker build -t "$CI_IMAGE" "$here/image" 2>&1 | tail -5
plist com.eve.ci-runners supervisor.sh
if ! launchctl print "gui/$(id -u)/com.eve.ci-runners" >/dev/null 2>&1; then launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.eve.ci-runners.plist"; fi
echo "VM + image + supervisor are up. Next: register.sh"
