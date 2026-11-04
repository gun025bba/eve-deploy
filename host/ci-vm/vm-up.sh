#!/bin/bash
# Starts the CI VM in the foreground (launchd keeps it alive). Idempotent.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/ci-env.sh"
mkdir -p "$CI_HOME/empty"
exec colima start --profile "$CI_PROFILE" --foreground --activate=false
