#!/bin/sh
# Root-owned helper, run by the com.eve.restart-watcher LaunchDaemon whenever /opt/eve-gw/restart.trigger changes.
# It never reads the trigger file (which a non-admin account can write): it only restarts the one gateway service
# and then writes a fresh token into a root-owned directory so the deploy script can see that the restart happened.
set -u
DONE_DIR=/var/db/eve-restart
mkdir -p "$DONE_DIR" && chmod 755 "$DONE_DIR"
/bin/launchctl kickstart -k system/com.llmserving.gateway
tmp=$(/usr/bin/mktemp "$DONE_DIR/.done.XXXXXX") || exit 1
printf '%s.%s\n' "$(/bin/date +%s)" "$$" >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$DONE_DIR/done"
