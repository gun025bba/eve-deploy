# eve-deploy

How a merge into `main` becomes a running deploy on the host. No manual step except the merge itself.

```
develop ──(PR, labels)──> main ──> auto-release workflow (eve-serving / eve-web)
                                     plan    version from the PR labels
                                     build   gateway binary (arm64) or the UI file tree  +  sha256 + manifest.json
                                     release tag vX.Y.Z + GitHub release (created by GITHUB_TOKEN)
                                     deploy  self-hosted runner on the host -> bin/deploy -> eve-supervisor deploy/rollback
```

## Rules
- The only manual deploy step is merging `develop` into `main`. The merge is the deploy.
- Version: labels on the merged PR. `major` / `minor`; no label = patch. `no-release` or a docs-only change = no release.
- Minor and patch releases need no security review (CI passing is the gate). A **major** release needs the label `security-approved` on the PR
  **before** the tag exists; without it the run fails and creates no tag (add the label, re-run the workflow).
- Only essential security checks stop a release (hard fail); everything else is a warning.
- Transient errors are retried automatically (downloads: 5 retries; the deploy step waits up to 60 s for health).
- If the new gateway build is not healthy, eve-supervisor restores the previous build; `bin/deploy rollback gateway|web` asks for that by hand (web still swaps its own files).
- The result of every deploy is in the job summary and in `/opt/eve-gw/state/result.json` (`status`: success | unchanged | rolled-back | failed).

## Layout
| path | what |
|---|---|
| `bin/deploy` | `deploy gateway\|web VERSION [--from DIR]`, `rollback gateway\|web`. Gateway calls the supervisor control socket. Idempotent, one deploy at a time (lock). |
| `bin/pack` | builds `eve-gateway-X.Y.Z-darwin-arm64.tar.gz` (`eve-gw`, `eve-service`, `eve-supervisor`, `eve-admin`) / `eve-web-X.Y.Z.tar.gz` + `.sha256` + `manifest.json` |
| `bin/next-version` | version planner (labels, docs-only, major approval) |
| `host/` | one-time host setup (`setup.sh`): release/socket directories + non-admin runners |
| `deploy/` | the host operations files moved from eve-serving (launchd, pg-backup, searxng, ci); `deploy/nopasswd/` stays in eve-serving until the legacy deploy is removed |
| `tests/test.sh` | tests (no root, no network): `bash tests/test.sh` |

## Why the deploy account stays unprivileged
The runner account is not an admin. It writes the code directories (`bin`, `web`, `previous`, `state`), the supervisor release root (`/opt/eve-gw/deploy`), and talks to the supervisor control socket (`/opt/eve-gw/run/supervisor.sock`).
That socket lives in a directory mode `0700` owned by the same user. eve-supervisor (already running as that user) swaps `releases/<ver>`, restarts the child, checks health and `/_deploy/version`, and rolls back on failure.
The runner only makes outbound HTTPS connections; nothing is exposed.
The workflow chain runs on `push` to `main` only, so a pull request (including from a fork) can never run code on the host runner.

## One-time setup (admin)
1. Create this repository (public, like the other two: it holds no secrets) and push `main`.
2. On the host, as root: `EVE_RUN_USER=<login-account> bash host/setup.sh` (asks for one runner registration token per repository: Settings -> Actions -> Runners -> New self-hosted runner). `EVE_RUN_USER` is required. The script exits with a clear error when it is unset, and it refuses root and any account whose uid is 0. It also creates `/opt/eve-gw/deploy` (supervisor `release_root`) and `/opt/eve-gw/run` (control socket directory, mode 0700).
3. In `eve-serving` and `eve-web` rulesets: let GitHub Actions create tags (ruleset `release-tags`: add the GitHub Actions app to the bypass list).
4. Cutover: set the repository variable `AUTO_RELEASE=on` in each repository. Until then the workflow does nothing and the old pipeline stays in charge.
5. After two successful real deploys, remove the old pipeline (host privilege entry, Sigstore workflows, poller) in one reviewed PR.

Directory handoff, when an operator runs it by hand, takes the account only from `EVE_RUN_USER`. It exits with a clear error when that variable is unset, and it refuses root and any account whose uid is 0:

```bash
[ -n "${EVE_RUN_USER:-}" ] || { echo "EVE_RUN_USER is required: set it to the login account that owns the deploy directories and the runner." >&2; exit 1; }; { [ "$EVE_RUN_USER" != root ] && [ "$(id -u "$EVE_RUN_USER" 2>/dev/null || true)" != 0 ]; } || { echo "refusing: $EVE_RUN_USER is root (uid 0). The runner must not be root." >&2; exit 1; }; sudo launchctl bootout system/com.eve.restart-watcher || true; sudo rm -f /Library/LaunchDaemons/com.eve.restart-watcher.plist /usr/local/libexec/eve-restart-watcher /opt/eve-gw/restart.trigger; sudo launchctl bootout system/com.llmserving.gateway || true; sudo install -d -o "$EVE_RUN_USER" -m 0700 /opt/eve-gw/deploy /opt/eve-gw/run; sudo chown "$EVE_RUN_USER" /opt/eve-gw/deploy /opt/eve-gw/run; sudo chmod 0700 /opt/eve-gw/deploy /opt/eve-gw/run
```

The server is moving to a single login-user account (LaunchAgent); the actual cutover is a separate runbook script.

## Supervisor layout and migrations (contract C4/C5)

- `deploy gateway VERSION` unpacks `eve-gw`, `eve-service`, `eve-supervisor` and `eve-admin` into `$EVE_RELEASE_ROOT/releases/<ver>/bin/` (default release root `/opt/eve-gw/deploy`) and sends `{"command":"deploy","child":"<name>","version":"<ver>"}` on the control socket. `EVE_SUPERVISOR_CHILDREN` (default `gateway`) is the child list. Each child’s `executable` in the supervisor config is the path inside the release, `bin/eve-gw` for the gateway.
- The socket directory must be mode `0700`, owned by the deploy user, and not a symlink. The socket file itself is mode `0600`. eve-deploy refuses anything else.
- Health, `/_deploy/version`, and automatic rollback belong to eve-supervisor. `result.json` keeps the old summary: `success`, `unchanged`, `rolled-back` (`health` `restored` or `restore-failed`), or `failed`.
- `deploy rollback gateway` sends `{"command":"rollback","child":"<name>"}`. Web deploys still swap files and poll `EVE_UI_URL`.
- The gateway migrates its own database at start (`GW_DB_AUTO_MIGRATE=true` in `deploy/launchd-go/gateway.plist.template` for installs that still use that template). The deploy account has no database credentials; a rollback is the previous binary (migrations are forward-only and expand-only).
- `manifest.json` is optional: if the release has one, component and version must match.
