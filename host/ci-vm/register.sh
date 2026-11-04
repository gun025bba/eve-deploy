#!/bin/bash
# One-time registration of the CI runners (label eve-ci). No sudo, no admin on the Mac. The token needs repo admin on GitHub:
#   repo -> Settings -> Actions -> Runners -> New self-hosted runner -> the token after --token (valid 1 hour; the same token serves all slots).
# Tokens come from the terminal (hidden) or RUNNER_TOKEN_EVE_SERVING / RUNNER_TOKEN_EVE_WEB, and are never written to disk.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/ci-env.sh"
docker info >/dev/null 2>&1 || { echo "CI VM is not running (launchctl kickstart gui/$(id -u)/com.eve.ci-vm)"; exit 1; }
for spec in $CI_REPOS; do
  repo=${spec%%:*}; slots=${spec##*:}
  var="RUNNER_TOKEN_$(echo "$repo" | tr 'a-z-' 'A-Z_')"; token=${!var:-}
  if [ -z "$token" ]; then printf 'registration token for %s/%s (hidden, Enter to skip): ' "$OWNER" "$repo"; read -rs token; echo; fi
  [ -n "$token" ] || { echo "  $repo: skipped"; continue; }
  for n in $(seq 1 "$slots"); do
    vol="eveci-cfg-$repo-$n"
    docker volume create "$vol" >/dev/null
    docker run --rm --user 0 -v "$vol":/cfg --entrypoint chown "$CI_IMAGE" 1001:1001 /cfg
    docker run --rm -v "$vol":/cfg -e REPO_URL="https://github.com/$OWNER/$repo" -e RUNNER_TOKEN="$token" -e RUNNER_NAME="eve-ci-$repo-$n" "$CI_IMAGE" register
    echo "  $repo slot $n registered"
  done
  token=""
done
echo "Done. GitHub -> each repo -> Settings -> Actions -> Runners should show eve-ci-* Idle within a minute."
