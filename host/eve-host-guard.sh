#!/bin/bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED for the eve-host runners (deploy host): a job may only run here when it was started by a push to main
# of this repository. A pull request that edits `runs-on` in its own workflow file to [self-hosted, eve-host] is stopped here,
# before any of its steps run. Pull request CI uses the isolated runner label eve-ci (Linux VM) instead.
set -eu
if [ "${GITHUB_EVENT_NAME:-}" = push ] && [ "${GITHUB_REF:-}" = refs/heads/main ]; then exit 0; fi
echo "eve-host runs only push-to-main jobs (event=${GITHUB_EVENT_NAME:-?} ref=${GITHUB_REF:-?}); use runs-on: [self-hosted, eve-ci]" >&2
exit 1
