#!/bin/bash
# One loop per runner slot: `docker run --rm` a fresh container that takes exactly one job, then it is gone (workspace, temp,
# caches and processes with it). The container has no mounts except the read-only registration copy.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/ci-env.sh"
until docker info >/dev/null 2>&1; do sleep 5; done
slot_loop() { # $1 repo $2 n
  local repo=$1 n=$2 vol="eveci-cfg-$1-$2"
  until docker volume inspect "$vol" >/dev/null 2>&1 && [ -n "$(docker run --rm -v "$vol":/cfg:ro --entrypoint ls "$CI_IMAGE" -A /cfg 2>/dev/null)" ]; do sleep 30; done  # waits for register.sh
  while true; do
    docker run --rm --name "eveci-$repo-$n" \
      -v "$vol":/cfg:ro \
      --cap-drop ALL --security-opt no-new-privileges --pids-limit 4096 \
      --memory "$CI_JOB_MEMORY" --cpus "$CI_JOB_CPUS" \
      "$CI_IMAGE" run
    sleep 3
  done
}
for spec in $CI_REPOS; do
  repo=${spec%%:*}; slots=${spec##*:}
  for n in $(seq 1 "$slots"); do slot_loop "$repo" "$n" & sleep 1; done
done
wait
