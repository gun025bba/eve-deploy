#!/bin/bash
# register: one-time, writes the runner's registration files to /cfg (a docker volume, mounted read-write only for this step)
# run:      copies the registration to a private copy of the runner, takes ONE job (run.sh --once) and exits; the container is then removed.
set -euo pipefail
SRC=/opt/actions-runner; W=/home/runner/actions-runner
cp -a "$SRC" "$W"; cd "$W"
case "${1:-}" in
  register)
    : "${REPO_URL:?}" "${RUNNER_TOKEN:?}" "${RUNNER_NAME:?}"
    ./config.sh --unattended --url "$REPO_URL" --token "$RUNNER_TOKEN" --name "$RUNNER_NAME" --labels eve-ci --work _work --replace --disableupdate
    cp .runner .credentials .credentials_rsaparams /cfg/
    ;;
  run)
    cp /cfg/.runner /cfg/.credentials /cfg/.credentials_rsaparams "$W"/
    exec ./run.sh --once
    ;;
  *) echo "usage: register|run" >&2; exit 2 ;;
esac
