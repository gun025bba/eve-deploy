# eve-deploy

How a merge into `main` becomes a running deploy on the host. No manual step except the merge itself.

```
develop ──(PR, labels)──> main ──> auto-release workflow (eve-serving / eve-web)
                                     plan    version from the PR labels
                                     build   gateway binary (arm64) or the UI file tree  +  sha256 + manifest.json
                                     release tag vX.Y.Z + GitHub release (created by GITHUB_TOKEN)
                                     deploy  self-hosted runner on the host -> bin/deploy -> health check -> automatic rollback
```

## Rules
- The only manual deploy step is merging `develop` into `main`. The merge is the deploy.
- Version: labels on the merged PR. `major` / `minor`; no label = patch. `no-release` or a docs-only change = no release.
- Minor and patch releases need no security review (CI passing is the gate). A **major** release needs the label `security-approved` on the PR
  **before** the tag exists; without it the run fails and creates no tag (add the label, re-run the workflow).
- Only essential security checks stop a release (hard fail); everything else is a warning.
- Transient errors are retried automatically (downloads: 5 retries; the deploy step waits up to 60 s for health).
- If the new version is not healthy the previous one is restored automatically; `bin/deploy rollback gateway|web` does it by hand.
- The result of every deploy is in the job summary and in `/opt/eve-gw/state/result.json` (`status`: success | unchanged | rolled-back | failed).

## Layout
| path | what |
|---|---|
| `bin/deploy` | `deploy gateway\|web VERSION [--from DIR]`, `rollback gateway\|web`. Contract C3. Idempotent, one deploy at a time (lock), no sudo. |
| `bin/pack` | builds `eve-gateway-X.Y.Z-darwin-arm64.tar.gz` / `eve-web-X.Y.Z.tar.gz` + `.sha256` + `manifest.json` |
| `bin/next-version` | version planner (labels, docs-only, major approval) |
| `host/` | one-time host setup (`setup.sh`): restart watcher + non-admin runners |
| `deploy/` | the host operations files moved from eve-serving (launchd, pg-backup, searxng, ci); `deploy/nopasswd/` stays in eve-serving until the legacy deploy is removed |
| `tests/test.sh` | tests (no root, no network): `bash tests/test.sh` |

## Why no sudo
The runner account is not an admin. It writes only the code directories (`bin`, `web`, `previous`, `state`) and touches `restart.trigger`.
A tiny root-owned LaunchDaemon (`host/restart-watcher.sh`) watches that file, restarts the one gateway service and writes a fresh token into a
root-owned directory; it never reads the trigger file. The runner only makes outbound HTTPS connections; nothing is exposed.
The workflow chain runs on `push` to `main` only, so a pull request (including from a fork) can never run code on the host runner.

## One-time setup (admin)
1. Create this repository (public, like the other two: it holds no secrets) and push `main`.
2. On the host: `sudo bash host/setup.sh` (asks for one runner registration token per repository: Settings -> Actions -> Runners -> New self-hosted runner).
3. In `eve-serving` and `eve-web` rulesets: let GitHub Actions create tags (ruleset `release-tags`: add the GitHub Actions app to the bypass list).
4. Cutover: set the repository variable `AUTO_RELEASE=on` in each repository. Until then the workflow does nothing and the old pipeline stays in charge.
5. After two successful real deploys, remove the old pipeline (sudoers entry, Sigstore workflows, poller) in one reviewed PR.
