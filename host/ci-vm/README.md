# CI VM (label `eve-ci`)

Pull-request CI runs in an isolated Linux VM on the deploy Mac, never as the deploy account on the host.
No sudo, no extra macOS account: everything belongs to the logged-in user that owns Homebrew.

```
Mac (deploy host)
 ├─ eve-host runners (user evedeploy): ONLY deploy + merged-main jobs        label eve-host
 └─ colima profile "eveci" (Apple Virtualization.framework, Linux arm64 VM)
      └─ one throwaway container per job (image eve-ci-runner:1)             label eve-ci
```

| Security condition | How |
|---|---|
| PR code cannot reach deploy credentials / home / launchd / prod data | VM has no host mounts (one empty read-only dir only; colima would mount the whole home otherwise). The VM cannot reach the Mac or any private/tailnet address (iptables `DOCKER-USER`, see `colima-eveci.yaml`). Containers run non-root, `--cap-drop ALL`, `no-new-privileges`, memory/CPU/pids limits. |
| Deploy jobs use a separate label | `deploy` (and `pim-helper-macos`) = `[self-hosted, eve-host]`; everything else = `[self-hosted, eve-ci]`. `eve-host-guard.sh` (root-owned runner hook, `guard-install.sh`, needs sudo once) makes eve-host refuse any job that is not a push to main, so a PR that edits `runs-on` cannot land on the host. |
| Workspace cleaned after each job | `docker run --rm` + `run.sh --once`: the container (workspace, temp, caches, processes) is deleted after one job. |
| No `pull_request_target`, no fork PR runs | none of the workflows use it; PR jobs have an `if` fork guard. |

Files: `setup.sh` (VM, image, launchd agents `com.eve.ci-vm` and `com.eve.ci-runners`), `register.sh` (one-time runner registration; needs a
1-hour repo registration token per repo), `supervisor.sh` (one loop per slot), `image/` (Ubuntu 24.04 + Go tooling deps, PostgreSQL 17,
Python 3.12, Playwright 1.64.1 Chromium, NanumGothic/Noto fonts, pinned actions runner).
Runner registration files live in a docker volume per slot and are mounted read-only; the job gets a private copy.
Limits: the VM only runs while the user is logged in (LaunchAgents). The runner is pinned (`--disableupdate`): bump `RUNNER_VERSION` and rebuild when GitHub requires it.
