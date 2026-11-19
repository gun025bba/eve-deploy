#!/bin/bash
# Tests for bin/pack, bin/deploy and bin/next-version. No root, no network: a fake health server and a fake supervisor control socket stand in for the host.
# Runs on Linux and macOS (system bash 3.2).   bash tests/test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/.." && pwd)
T=$(mktemp -d); PASS=0; FAILN=0
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; [ -n "${CTL:-}" ] && kill "$CTL" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# ---------- fake host ----------
export EVE_ROOT=$T/root EVE_RELEASE_ROOT=$T/root/deploy EVE_CONTROL_SOCKET=$T/run/supervisor.sock EVE_HEALTH_WAIT=4
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
export EVE_UI_URL=http://127.0.0.1:$PORT/ui/
mkdir -p "$EVE_ROOT/bin" "$EVE_ROOT/web"
cat >"$T/srv.py" <<PY
import http.server, os
T="$T"; ROOT="$EVE_ROOT"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        code = 404
        if self.path == "/health": code = 503 if os.path.exists(T+"/unhealthy") else 200
        elif self.path.startswith("/ui/"):
            f = ROOT+"/web/index.html"; code = 200 if os.path.exists(f) and b"BAD" not in open(f,"rb").read() else 503
        self.send_response(code); self.end_headers()
http.server.HTTPServer(("127.0.0.1",$PORT),H).serve_forever()
PY
python3 "$T/srv.py" & SRV=$!
# fake eve-supervisor control socket. Directory mode 0700, socket mode 0600 (eve-serving #265).
cat >"$T/ctl.py" <<PY
import json, os, socket, threading
T="$T"; ROOT="$EVE_RELEASE_ROOT"; SOCK="$EVE_CONTROL_SOCKET"; LOG="$T/sock.log"
os.makedirs(os.path.dirname(SOCK), mode=0o700)
os.chmod(os.path.dirname(SOCK), 0o700)
if os.path.exists(SOCK): os.remove(SOCK)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK); os.chmod(SOCK, 0o600); srv.listen(16)
state = {}
def handle(conn):
    try:
        data = b""
        while len(data) < 65536:
            b = conn.recv(4096)
            if not b: break
            data += b
            if b"\\n" in data: break
        req = json.loads(data.decode() or "{}")
        with open(LOG, "a") as f: f.write(json.dumps(req, sort_keys=True) + "\\n")
        child, cmd = req.get("child", ""), req.get("command", "")
        cur, prev = state.get(child, ["", ""])
        res = {"ok": False, "action": cmd, "child": child, "from": cur, "to": "", "rolled_back": False}
        if cmd == "deploy":
            ver = req.get("version", ""); res["to"] = ver
            if ver == cur and cur != "":
                res["error"] = "version is already current"
            else:
                marker = ""
                p = os.path.join(ROOT, "releases", ver, "bin", "eve-gw")
                if os.path.isfile(p): marker = open(p).read()
                if "UNHEALTHY" in marker or "STALE" in marker:
                    res["rolled_back"] = True
                    res["rollback_healthy"] = "RESTORE_FAIL" not in marker
                    res["error"] = "version mismatch: running other" if "STALE" in marker else "health check timed out"
                elif "REJECT" in marker:
                    res["error"] = "release check failed"
                else:
                    state[child] = [ver, cur]; res["ok"] = True; res["from"] = cur; res["to"] = ver
        elif cmd == "rollback":
            if not prev: res["error"] = "no previous release"
            else:
                state[child] = [prev, cur]; res["ok"] = True; res["from"] = cur; res["to"] = prev
        elif cmd == "status":
            if os.path.exists(os.path.join(T, "status-fail")):
                return
            kids = [{"name": n, "current": p[0], "previous": p[1]} for n, p in state.items()]
            res = {"ok": True, "action": "status", "children": kids}
        else:
            res["error"] = "unknown command"
        open(os.path.join(T, "running"), "w").write(state.get("gateway", ["", ""])[0])
        conn.sendall((json.dumps(res) + "\\n").encode())
    finally:
        conn.close()
def serve():
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()
serve()
PY
python3 "$T/ctl.py" & CTL=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$EVE_CONTROL_SOCKET" ] && break; sleep 0.1; done

# ---------- helpers: build a gateway / web release with bin/pack ----------
mk_gw() { # version [marker]
  local d=$T/rel-gw-$1 b; mkdir -p "$d/in"
  printf '#!/bin/sh\n# %s\n[ "$1" = -version ] && echo %s\nexit 0\n' "${2:-ok}" "$1" >"$d/in/eve-gw"; chmod +x "$d/in/eve-gw"
  for b in eve-service eve-supervisor eve-admin; do cp "$d/in/eve-gw" "$d/in/$b"; done
  bash "$R/bin/pack" gateway --version "$1" --commit 0123456789abcdef0123456789abcdef01234567 \
    --eve-gw "$d/in/eve-gw" --eve-service "$d/in/eve-service" --eve-supervisor "$d/in/eve-supervisor" --eve-admin "$d/in/eve-admin" \
    --out "$d/out" >/dev/null && echo "$d/out"
}
mode_of() { python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "04o"))' "$1"; }
mk_web() { # version [BAD]
  local d=$T/rel-web-$1; mkdir -p "$d/repo"; ( cd "$d/repo" && git init -q . && printf '<html>%s %s</html>\n' "$1" "${2:-good}" >index.html && echo "x" >README.md && mkdir -p tests && echo t >tests/a && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
  bash "$R/bin/pack" web --version "$1" --commit 0123456789abcdef0123456789abcdef01234567 --web-dir "$d/repo" --out "$d/out" >/dev/null && echo "$d/out"
}
D="bash $R/bin/deploy"
res() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" "$EVE_ROOT/state/result.json"; }

echo "== pack"
G1=$(mk_gw 1.0.0); [ -f "$G1/eve-gateway-1.0.0-darwin-arm64.tar.gz" ] && [ -f "$G1/manifest.json" ] && ok "gateway files produced" || bad "gateway files produced"
check "gateway tar is the four binaries" "$(tar -tzf "$G1/eve-gateway-1.0.0-darwin-arm64.tar.gz" | sort | tr '\n' ' ')" "eve-admin eve-gw eve-service eve-supervisor "
check "sha256 file matches the tarball" "$(awk '{print $1}' "$G1/eve-gateway-1.0.0-darwin-arm64.tar.gz.sha256")" "$(sha_of "$G1/eve-gateway-1.0.0-darwin-arm64.tar.gz")"
W1=$(mk_web 1.0.0); check "web tar excludes README.md and tests/" "$(tar -tzf "$W1/eve-web-1.0.0.tar.gz" | sort | tr '\n' ' ')" "index.html "
if bash "$R/bin/pack" gateway --version 1.0 --commit 0123456789abcdef0123456789abcdef01234567 --eve-gw x --eve-service x --eve-supervisor x --eve-admin x --out "$T/o" >/dev/null 2>&1; then bad "pack refuses a bad version"; else ok "pack refuses a bad version"; fi
if bash "$R/bin/pack" gateway --version 1.0.0 --commit 0123456789abcdef0123456789abcdef01234567 --gateway x --eve-gw x --eve-service x --eve-supervisor x --eve-admin x --out "$T/o" >/dev/null 2>&1; then bad "pack refuses the old --gateway argument"; else ok "pack refuses the old --gateway argument"; fi

# web tree with a symlink / without index.html is refused
mkdir -p "$T/sl" && ( cd "$T/sl" && git init -q . && echo h >index.html && ln -s /etc/passwd evil && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
if bash "$R/bin/pack" web --version 1.0.0 --commit 0123456789abcdef0123456789abcdef01234567 --web-dir "$T/sl" --out "$T/slo" >/dev/null 2>&1; then bad "pack refuses a web tree with a symlink"; else ok "pack refuses a web tree with a symlink"; fi

echo "== gateway deploy"
check "control socket directory is 0700" "$(mode_of "$(dirname "$EVE_CONTROL_SOCKET")")" 0700
check "control socket is 0600" "$(mode_of "$EVE_CONTROL_SOCKET")" 0600
$D deploy gateway 1.0.0 --from "$G1" >"$T/o1" 2>&1; check "first deploy exits 0" "$?" 0
check "state says 1.0.0" "$(cat "$EVE_ROOT/state/gateway.version")" 1.0.0
check "result.json status" "$(res status)" success
check "installed eve-gw runs" "$("$EVE_RELEASE_ROOT/releases/1.0.0/bin/eve-gw" -version)" 1.0.0
check "release directory is 0700" "$(mode_of "$EVE_RELEASE_ROOT/releases/1.0.0")" 0700
check "supervisor deploy was called" "$(grep -c '{"child": "gateway", "command": "deploy", "version": "1.0.0"}' "$T/sock.log")" 1
check "supervisor reports 1.0.0 current" "$(cat "$T/running")" 1.0.0
$D deploy gateway 1.0.0 --from "$G1" >/dev/null 2>&1; check "same version again: exit 0" "$?" 0; check "same version again: unchanged" "$(res status)" unchanged
check "same version does not call the socket again" "$(grep -c '"command": "deploy"' "$T/sock.log")" 1
G2=$(mk_gw 1.1.0)
$D deploy gateway 1.1.0 --from "$G2" >/dev/null 2>&1; check "update exits 0" "$?" 0
check "previous version kept" "$(cat "$EVE_ROOT/state/gateway.previous")" 1.0.0
check "result.json from/to" "$(res from)->$(res to)" "1.0.0->1.1.0"
check "supervisor now on 1.1.0" "$(cat "$T/running")" 1.1.0
G3=$(mk_gw 1.2.0 UNHEALTHY)
$D deploy gateway 1.2.0 --from "$G3" >/dev/null 2>&1; check "unhealthy release exits 1" "$?" 1
check "unhealthy release: status rolled-back" "$(res status)" rolled-back
check "unhealthy release: health restored" "$(res health)" restored
check "unhealthy release: supervisor stayed on 1.1.0" "$(cat "$T/running")" 1.1.0
check "unhealthy release: state unchanged" "$(cat "$EVE_ROOT/state/gateway.version")" 1.1.0
$D rollback gateway >/dev/null 2>&1; check "rollback exits 0" "$?" 0
check "rollback: supervisor now 1.0.0" "$(cat "$T/running")" 1.0.0
check "rollback: state" "$(cat "$EVE_ROOT/state/gateway.version")" 1.0.0
check "rollback called the socket" "$(grep -c '{"child": "gateway", "command": "rollback"}' "$T/sock.log")" 1
# tampered tarball
G4=$(mk_gw 1.3.0); echo junk >>"$G4/eve-gateway-1.3.0-darwin-arm64.tar.gz"
$D deploy gateway 1.3.0 --from "$G4" >"$T/o4" 2>&1; check "tampered tarball refused" "$?" 1
grep -q "sha256" "$T/o4" && ok "tampered tarball: reason is the sha256" || bad "tampered tarball: reason is the sha256"
check "tampered tarball: nothing changed" "$(cat "$T/running")" 1.0.0
# manifest of another version
G5=$(mk_gw 1.4.0); sed -i.bak 's/"version": "1.4.0"/"version": "9.9.9"/' "$G5/manifest.json"
$D deploy gateway 1.4.0 --from "$G5" >/dev/null 2>&1; check "manifest/version mismatch refused" "$?" 1
# unsafe tar path
mkdir -p "$T/evil" && ( cd "$T/evil" && mkdir -p a && echo x >a/x && tar -czf eve-gateway-1.5.0-darwin-arm64.tar.gz -s '#^a/x#../x#' a/x 2>/dev/null || tar -czf eve-gateway-1.5.0-darwin-arm64.tar.gz --transform='s#^a/x#../x#' a/x 2>/dev/null )
if [ -f "$T/evil/eve-gateway-1.5.0-darwin-arm64.tar.gz" ]; then
  H=$(sha_of "$T/evil/eve-gateway-1.5.0-darwin-arm64.tar.gz"); echo "$H  eve-gateway-1.5.0-darwin-arm64.tar.gz" >"$T/evil/eve-gateway-1.5.0-darwin-arm64.tar.gz.sha256"
  printf '{"component":"gateway","version":"1.5.0","commit":"x"}\n' >"$T/evil/manifest.json"
  $D deploy gateway 1.5.0 --from "$T/evil" >/dev/null 2>&1; check "tar with .. path refused" "$?" 1
else ok "tar with .. path refused (tar cannot build the sample here: skipped)"; fi
# a release containing a symlink is refused
mkdir -p "$T/ln/in" && ( cd "$T/ln/in" && printf '#!/bin/sh\nexit 0\n' >eve-gw && chmod +x eve-gw && ln -s /etc/passwd eve-service && tar -czf ../eve-gateway-1.5.1-darwin-arm64.tar.gz eve-gw eve-service )
H=$(sha_of "$T/ln/eve-gateway-1.5.1-darwin-arm64.tar.gz"); echo "$H  x" >"$T/ln/eve-gateway-1.5.1-darwin-arm64.tar.gz.sha256"; printf '{"component":"gateway","version":"1.5.1","commit":"x"}\n' >"$T/ln/manifest.json"
$D deploy gateway 1.5.1 --from "$T/ln" >/dev/null 2>&1; check "tar with a symlink refused" "$?" 1
# supervisor reports a version mismatch: the deploy is rolled back and state stays
G6=$(mk_gw 1.6.0 STALE); $D deploy gateway 1.6.0 --from "$G6" >/dev/null 2>&1; check "stale process (wrong version answers) is rolled back" "$?" 1
check "stale process: status" "$(res status)" rolled-back
check "stale process: still on the old version" "$(cat "$EVE_ROOT/state/gateway.version")" 1.0.0
# a release without manifest.json (made by hand) deploys
G7=$(mk_gw 1.7.0); rm "$G7/manifest.json"; $D deploy gateway 1.7.0 --from "$G7" >/dev/null 2>&1; check "release without manifest.json deploys" "$?" 0
# supervisor rejects the release before swapping: nothing is rolled back because nothing switched
GR=$(mk_gw 1.8.0 REJECT); $D deploy gateway 1.8.0 --from "$GR" >/dev/null 2>&1; check "rejected release exits 1" "$?" 1
check "rejected release: status failed" "$(res status)" failed
check "rejected release: still 1.7.0" "$(cat "$T/running")" 1.7.0
# supervisor rolled back but the restored build is not healthy
GF=$(mk_gw 1.9.0 'UNHEALTHY RESTORE_FAIL'); $D deploy gateway 1.9.0 --from "$GF" >/dev/null 2>&1; check "restore failure exits 1" "$?" 1
check "restore failure: status rolled-back" "$(res status)" rolled-back
check "restore failure: health restore-failed" "$(res health)" restore-failed
check "restore failure: state unchanged" "$(cat "$EVE_ROOT/state/gateway.version")" 1.7.0
# the production plist template turns on startup migrations (BE decision, C5). setup no longer edits a gateway daemon.
grep -q '<key>GW_DB_AUTO_MIGRATE</key><string>true</string>' "$R/deploy/launchd-go/gateway.plist.template" && ok "plist template sets GW_DB_AUTO_MIGRATE=true" || bad "plist template sets GW_DB_AUTO_MIGRATE=true"
if grep -q 'restart-watcher\|com.llmserving.gateway' "$R/host/setup.sh"; then bad "setup still installs the watcher or gateway daemon"; else ok "setup does not install the watcher or gateway daemon"; fi
if grep -q 'evedeploy' "$R/host/setup.sh" "$R/README.md"; then bad "setup and README name no default account"; else ok "setup and README name no default account"; fi
OUT=$(env -u EVE_RUN_USER bash "$R/host/setup.sh" 2>&1)
check "setup without EVE_RUN_USER exits 1" "$?" 1
echo "$OUT" | grep -q 'EVE_RUN_USER is required' && ok "setup without EVE_RUN_USER says it is required" || bad "setup without EVE_RUN_USER says it is required"
OUT=$(env -u EVE_RUN_USER RUNNER_USER=somebody bash "$R/host/setup.sh" 2>&1)
check "RUNNER_USER alone is not the run account" "$?" 1
grep -q 'EVE_RUN_USER is required' "$R/README.md" && ok "README cutover one-liner requires EVE_RUN_USER" || bad "README cutover one-liner requires EVE_RUN_USER"
grep -q 'single login-user account (LaunchAgent); the actual cutover is a separate runbook script' "$R/README.md" && ok "README records the LaunchAgent move and separate runbook" || bad "README records the LaunchAgent move and separate runbook"
grep -q 'eve_check_run_user' "$R/host/setup.sh" && grep -q 'host/setup.sh --check-run-user' "$R/README.md" && ok "one-liner calls the setup run-user check" || bad "one-liner calls the setup run-user check"
awk '/^```bash$/{p=1;next} /^```$/{if(p) exit} p' "$R/README.md" >"$T/cutover.sh"
run_cutover() { ( cd "$R" && env "$@" bash -c 'sudo() { printf "sudo %s\n" "$*"; }; . "$1"' _ "$T/cutover.sh" 2>&1 ); }
OUT=$(run_cutover -u EVE_RUN_USER)
check "cutover one-liner without EVE_RUN_USER exits 1" "$?" 1
echo "$OUT" | grep -q 'EVE_RUN_USER is required' && ok "cutover one-liner says EVE_RUN_USER is required" || bad "cutover one-liner says EVE_RUN_USER is required"
mkdir -p "$T/idbin"
cat >"$T/idbin/id" <<'SH'
#!/bin/bash
if [ "$1" = -un ]; then printf '%s\n' "${MOCK_ID_NAME:-login-account}"; exit 0; fi
if [ "$1" = -u ] && [ -z "${2:-}" ]; then printf '%s\n' "${MOCK_ID_UID:-501}"; exit 0; fi
user=$1
if [ "$1" = -u ]; then user=$2; fi
case "$user" in
  login-account) [ "$1" = -u ] && echo 501; exit 0 ;;
  toor) [ "$1" = -u ] && echo 0; exit 0 ;;
  adminuser) [ "$1" = -u ] && echo 501; exit 0 ;;
  other-admin) [ "$1" = -u ] && echo 501; exit 0 ;;
esac
exit 1
SH
cat >"$T/idbin/dscl" <<'SH'
#!/bin/bash
printf '%s\n' "${DSCL_MEMBERSHIP:-GroupMembership: root admin}"
SH
cat >"$T/idbin/stat" <<'SH'
#!/bin/bash
if [ "${MOCK_CONSOLE_UNSET:-}" = 1 ]; then exit 0; fi
if [ -n "${MOCK_CONSOLE_USER:-}" ]; then printf '%s\n' "$MOCK_CONSOLE_USER"; fi
exit 0
SH
chmod +x "$T/idbin/id" "$T/idbin/dscl" "$T/idbin/stat"
OUT=$(PATH="$T/idbin:$PATH" run_cutover EVE_RUN_USER=login-account)
echo "$OUT" | grep -q 'install -d -o login-account ' && ok "cutover one-liner passes EVE_RUN_USER to install" || bad "cutover one-liner passes EVE_RUN_USER to install"
echo "$OUT" | grep -q 'chown login-account ' && ok "cutover one-liner passes EVE_RUN_USER to chown" || bad "cutover one-liner passes EVE_RUN_USER to chown"
OUT=$(env EVE_RUN_USER=root bash "$R/host/setup.sh" 2>&1)
check "setup refuses the name root" "$?" 1
echo "$OUT" | grep -q 'refusing: root is root (uid 0)' && ok "setup says root is refused" || bad "setup says root is refused"
OUT=$(run_cutover EVE_RUN_USER=root)
check "cutover one-liner refuses the name root" "$?" 1
echo "$OUT" | grep -q 'refusing: root is root (uid 0)' && ok "cutover one-liner says root is refused" || bad "cutover one-liner says root is refused"
echo "$OUT" | grep -q 'install -d' && bad "cutover one-liner stops before install for root" || ok "cutover one-liner stops before install for root"
OUT=$(PATH="$T/idbin:$PATH" env EVE_RUN_USER=toor bash "$R/host/setup.sh" 2>&1)
check "setup refuses uid 0 under another name" "$?" 1
echo "$OUT" | grep -q 'refusing: toor is root (uid 0)' && ok "setup says the uid 0 account is refused" || bad "setup says the uid 0 account is refused"
OUT=$(PATH="$T/idbin:$PATH" run_cutover EVE_RUN_USER=toor)
check "cutover one-liner refuses uid 0 under another name" "$?" 1
echo "$OUT" | grep -q 'refusing: toor is root (uid 0)' && ok "cutover one-liner says the uid 0 account is refused" || bad "cutover one-liner says the uid 0 account is refused"
echo "$OUT" | grep -q 'install -d' && bad "cutover one-liner stops before install for uid 0" || ok "cutover one-liner stops before install for uid 0"
OUT=$(env EVE_RUN_USER=eve-no-such-account bash "$R/host/setup.sh" 2>&1)
check "setup refuses a missing account" "$?" 1
echo "$OUT" | grep -q 'account eve-no-such-account does not exist' && ok "setup says the account does not exist" || bad "setup says the account does not exist"
OUT=$(run_cutover EVE_RUN_USER=eve-no-such-account)
check "cutover one-liner refuses a missing account" "$?" 1
echo "$OUT" | grep -q 'account eve-no-such-account does not exist' && ok "cutover one-liner says the account does not exist" || bad "cutover one-liner says the account does not exist"
echo "$OUT" | grep -q 'install -d' && bad "cutover one-liner stops before install for a missing account" || ok "cutover one-liner stops before install for a missing account"
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin adminuser' env MOCK_ID_UID=501 MOCK_ID_NAME=adminuser EVE_RUN_USER=adminuser bash "$R/host/setup.sh" --check-run-user 2>&1)
check "setup allows an admin account that is the current user" "$?" 0
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin adminuser' run_cutover MOCK_ID_UID=501 MOCK_ID_NAME=adminuser EVE_RUN_USER=adminuser)
echo "$OUT" | grep -q 'install -d -o adminuser ' && ok "cutover one-liner allows an admin account that is the current user" || bad "cutover one-liner allows an admin account that is the current user"
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin other-admin' env MOCK_ID_UID=501 MOCK_ID_NAME=login-account EVE_RUN_USER=other-admin bash "$R/host/setup.sh" --check-run-user 2>&1)
check "setup refuses an admin account that is not the current user" "$?" 1
echo "$OUT" | grep -q 'refusing: other-admin is an admin account and is not the current user' && ok "setup says the other admin is not the current user" || bad "setup says the other admin is not the current user"
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin other-admin' run_cutover MOCK_ID_UID=501 MOCK_ID_NAME=login-account EVE_RUN_USER=other-admin)
check "cutover one-liner refuses an admin account that is not the current user" "$?" 1
echo "$OUT" | grep -q 'install -d' && bad "cutover one-liner stops before install for another admin" || ok "cutover one-liner stops before install for another admin"
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin adminuser' env -u SUDO_USER MOCK_ID_UID=0 MOCK_CONSOLE_USER=adminuser SUDO_USER=adminuser EVE_RUN_USER=adminuser bash "$R/host/setup.sh" --check-run-user 2>&1)
check "sudo setup allows an admin account that matches SUDO_USER and the console user" "$?" 0
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin other-admin' env -u SUDO_USER MOCK_ID_UID=0 MOCK_CONSOLE_USER=login-account SUDO_USER=login-account EVE_RUN_USER=other-admin bash "$R/host/setup.sh" --check-run-user 2>&1)
check "sudo setup refuses an admin account that is not SUDO_USER" "$?" 1
echo "$OUT" | grep -q 'is not the sudo user' && ok "sudo setup says the admin is not the sudo user" || bad "sudo setup says the admin is not the sudo user"
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin adminuser' env -u SUDO_USER MOCK_ID_UID=0 MOCK_CONSOLE_USER=login-account SUDO_USER=adminuser EVE_RUN_USER=adminuser bash "$R/host/setup.sh" --check-run-user 2>&1)
check "sudo setup refuses an admin account that is not the console user" "$?" 1
echo "$OUT" | grep -q 'is not the console login account' && ok "sudo setup says the admin is not the console user" || bad "sudo setup says the admin is not the console user"
OUT=$(PATH="$T/idbin:$PATH" DSCL_MEMBERSHIP='GroupMembership: root admin adminuser' env -u SUDO_USER MOCK_ID_UID=0 MOCK_CONSOLE_UNSET=1 EVE_RUN_USER=adminuser bash "$R/host/setup.sh" --check-run-user 2>&1)
check "sudo setup refuses an admin account when both identities are unknown" "$?" 1
echo "$OUT" | grep -q 'both unknown' && ok "sudo setup says both identities are unknown" || bad "sudo setup says both identities are unknown"
# a socket directory other people can enter is refused (#265)
chmod 755 "$(dirname "$EVE_CONTROL_SOCKET")"
BEFORE=$(wc -l <"$T/sock.log" | tr -d ' ')
$D deploy gateway 3.0.0 --from "$(mk_gw 3.0.0)" >"$T/o755" 2>&1; check "0755 socket directory is refused" "$?" 1
grep -q '0700' "$T/o755" && ok "0755 socket directory: reason is 0700" || bad "0755 socket directory: reason is 0700"
check "0755 socket directory: no command was sent" "$(wc -l <"$T/sock.log" | tr -d ' ')" "$BEFORE"
check "0755 socket directory: state unchanged" "$(cat "$EVE_ROOT/state/gateway.version")" 1.7.0
chmod 700 "$(dirname "$EVE_CONTROL_SOCKET")"
# a lock left by a running deploy blocks a second one
mkdir "$EVE_ROOT/state/lock"; $D deploy gateway 1.7.0 --from "$G6" >/dev/null 2>&1; check "second deploy while one runs is refused" "$?" 1; rmdir "$EVE_ROOT/state/lock"

echo "== gateway state dir and supervisor pointers"
SA=$T/stateA; SB=$T/stateB; SC=$T/stateC
GA=$(mk_gw 2.0.0); GB=$(mk_gw 2.1.0); GC=$(mk_gw 2.2.0); GD=$(mk_gw 2.4.0)
EVE_STATE_DIR=$SA $D deploy gateway 2.0.0 --from "$GA" >/dev/null 2>&1
EVE_STATE_DIR=$SA $D deploy gateway 2.1.0 --from "$GB" >/dev/null 2>&1
rm -f "$SA/gateway.version" "$SA/gateway.previous"
EVE_STATE_DIR=$SA $D deploy gateway 2.2.0 --from "$GC" >/dev/null 2>&1; check "empty state deploy uses supervisor current" "$?" 0
check "empty state records supervisor current as previous" "$(cat "$SA/gateway.previous")" 2.1.0
grep -q 'state has no gateway version; supervisor current is 2.1.0' "$SA/deploy.log" && ok "empty state logs the supervisor current" || bad "empty state logs the supervisor current"
EVE_STATE_DIR=$SA $D rollback gateway >/dev/null 2>&1; check "rollback after empty-state deploy exits 0" "$?" 0
check "rollback after empty-state deploy returns to supervisor previous" "$(cat "$SA/gateway.version")" 2.1.0
printf '9.9.9\n' >"$SA/gateway.previous"; printf '2.1.0\n' >"$SA/gateway.version"
EVE_STATE_DIR=$SA $D rollback gateway >"$T/rbdiff" 2>&1; check "rollback follows supervisor previous when state differs" "$?" 0
grep -q 'state previous 9.9.9 differs from supervisor previous 2.2.0: using the supervisor' "$SA/deploy.log" && ok "rollback logs the supervisor previous" || bad "rollback logs the supervisor previous"
check "rollback state version is the supervisor previous" "$(cat "$SA/gateway.version")" 2.2.0
EVE_STATE_DIR=$SB $D deploy gateway 2.0.0 --from "$GA" >/dev/null 2>&1; check "EVE_STATE_DIR deploy exits 0" "$?" 0
check "EVE_STATE_DIR holds the gateway version" "$(cat "$SB/gateway.version")" 2.0.0
check "default state dir is left unchanged" "$(cat "$EVE_ROOT/state/gateway.version")" 1.7.0
: >"$T/status-fail"
mkdir -p "$SC"; rm -f "$SC/gateway.version" "$SC/gateway.previous"
EVE_STATE_DIR=$SC $D deploy gateway 2.4.0 --from "$GD" >"$T/stfail" 2>&1; check "status failure does not stop the deploy" "$?" 0
grep -q 'supervisor status unavailable' "$SC/deploy.log" && ok "status failure is logged" || bad "status failure is logged"
check "status failure deploy records the new version" "$(cat "$SC/gateway.version")" 2.4.0
check "status failure leaves the empty previous from the state file" "$(cat "$SC/gateway.previous")" ""
printf '2.4.0\n' >"$SC/gateway.version"; printf '1.0.0\n' >"$SC/gateway.previous"
EVE_STATE_DIR=$SC $D rollback gateway >"$T/stfailrb" 2>&1; check "status failure rollback uses the state file" "$?" 0
check "status failure rollback keeps the state-file previous" "$(cat "$SC/gateway.version")" 1.0.0
grep -q 'differs from supervisor previous' "$T/stfailrb" && bad "status failure rollback does not follow a supervisor value" || ok "status failure rollback does not follow a supervisor value"
rm -f "$T/status-fail"

echo "== web deploy"
mkdir -p "$EVE_ROOT/previous"; chmod 555 "$EVE_ROOT"   # like production: the deploy user can not rename entries of $EVE_ROOT itself
$D deploy web 1.0.0 --from "$W1" >/dev/null 2>&1; check "web first deploy" "$?" 0
check "web tree is live" "$(cat "$EVE_ROOT/web/index.html")" "<html>1.0.0 good</html>"
W2=$(mk_web 1.1.0); $D deploy web 1.1.0 --from "$W2" >/dev/null 2>&1; check "web update" "$?" 0
check "web previous kept" "$(cat "$EVE_ROOT/previous/web/index.html")" "<html>1.0.0 good</html>"
W3=$(mk_web 1.2.0 BAD); $D deploy web 1.2.0 --from "$W3" >/dev/null 2>&1; check "bad web release exits 1" "$?" 1
check "bad web release: old tree restored" "$(cat "$EVE_ROOT/web/index.html")" "<html>1.1.0 good</html>"
check "bad web release: status" "$(res status)" rolled-back
$D rollback web >/dev/null 2>&1; check "web rollback" "$?" 0
check "web rollback: tree" "$(cat "$EVE_ROOT/web/index.html")" "<html>1.0.0 good</html>"

echo "== web deploy: failing moves (a mv shim fails one chosen move; EVE_ROOT stays read-only)"
mkdir -p "$T/shim"; cat >"$T/shim/mv" <<'SHIM'
#!/bin/bash
args=(); for a in "$@"; do case "$a" in -*) ;; *) args+=("$a");; esac; done
dst=${args[${#args[@]}-1]}
for s in "${args[@]:0:${#args[@]}-1}"; do
  [ -z "${MV_LOG:-}" ] || echo "$s $dst" >>"$MV_LOG"
  case "$s" in $MV_FAIL_SRC) case "$dst" in $MV_FAIL_DST)
    if [ -n "${MV_FAIL_ALWAYS:-}" ] || [ ! -e "$MV_FAIL_MARK" ]; then : >"$MV_FAIL_MARK"; echo "mv: injected failure" >&2; exit 1; fi;; esac;; esac
done
exec /bin/mv "$@"
SHIM
chmod +x "$T/shim/mv"
mk_webx() { # version: index.html, sw.js, app.js, zz.txt, a dot file and a sub directory
  local d=$T/relx-web-$1; mkdir -p "$d/repo/assets"; ( cd "$d/repo" && git init -q . && printf '<html>%s good</html>\n' "$1" >index.html && echo "sw $1" >sw.js && echo "app $1" >app.js && echo "zz $1" >zz.txt && echo "hid $1" >.hid && echo "css $1" >assets/a.css && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
  bash "$R/bin/pack" web --version "$1" --commit 0123456789abcdef0123456789abcdef01234567 --web-dir "$d/repo" --out "$d/out" >/dev/null && echo "$d/out"
}
snap() { ( cd "$1" 2>/dev/null && find . -type f | sort | while read -r f; do echo "$f $(sha_of "$f")"; done ) | tr '\n' ' '; }
reset_web() { find "$EVE_ROOT/web" -mindepth 1 -delete; rm -rf "$EVE_ROOT"/previous/web "$EVE_ROOT"/previous/web.old "$EVE_ROOT"/previous/web.swap "$EVE_ROOT/state/web.version" "$EVE_ROOT/state/web.previous"; }
fail_mv() { # src-glob dst-glob always -- command...   fails the first (or every, if always is set) matching mv
  local s=$1 d=$2 al=$3; shift 3; rm -f "$T/mvmark"
  PATH="$T/shim:$PATH" MV_FAIL_SRC="$s" MV_FAIL_DST="$d" MV_FAIL_MARK="$T/mvmark" MV_FAIL_ALWAYS="$al" "$@"
}
WX1=$(mk_webx 2.0.0); WX2=$(mk_webx 2.1.0); E=$EVE_ROOT
two_releases() { reset_web; $D deploy web 2.0.0 --from "$WX1" >/dev/null 2>&1; $D deploy web 2.1.0 --from "$WX2" >/dev/null 2>&1; }

reset_web; $D deploy web 2.0.0 --from "$WX1" >/dev/null 2>&1; BEFORE=$(snap "$E/web"); BP=$(snap "$E/previous/web")
check "setup: the 2.0.0 tree has 6 files incl. the dot file" "$(echo "$BEFORE" | grep -o ' ' | wc -l | tr -d ' ')" 12
fail_mv "$E/web/zz.txt" "$E/previous/web/" "" bash "$R/bin/deploy" deploy web 2.1.0 --from "$WX2" >/dev/null 2>&1; check "install, old files cannot be moved aside: exits 1" "$?" 1
check "install step 1 failed: the injected failure was hit" "$([ -e "$T/mvmark" ] && echo yes)" yes
check "install step 1 failed: every old live file is still there (none deleted)" "$(snap "$E/web")" "$BEFORE"
check "install step 1 failed: previous/web is as before" "$(snap "$E/previous/web")" "$BP"
check "install step 1 failed: version unchanged" "$(cat "$E/state/web.version")" 2.0.0

reset_web; $D deploy web 2.0.0 --from "$WX1" >/dev/null 2>&1; BEFORE=$(snap "$E/web"); BP=$(snap "$E/previous/web")
fail_mv "$E/state/work.*/new/zz.txt" "$E/web/" "" bash "$R/bin/deploy" deploy web 2.1.0 --from "$WX2" >/dev/null 2>&1; check "install, new files cannot be moved in: exits 1" "$?" 1
check "install step 2 failed: the injected failure was hit" "$([ -e "$T/mvmark" ] && echo yes)" yes
check "install step 2 failed: old live files are back, no new file is mixed in" "$(snap "$E/web")" "$BEFORE"
check "install step 2 failed: previous/web is as before" "$(snap "$E/previous/web")" "$BP"
check "install step 2 failed: no previous/web.old left" "$([ -e "$E/previous/web.old" ] && echo yes || echo no)" no
check "install step 2 failed: version unchanged" "$(cat "$E/state/web.version")" 2.0.0

two_releases; LIVE=$(snap "$E/web"); PREVS=$(snap "$E/previous/web")
check "setup: previous holds 2.0.0" "$(cat "$E/previous/web/index.html")" "<html>2.0.0 good</html>"
fail_mv "$E/web/zz.txt" "$E/previous/web.swap/" "" bash "$R/bin/deploy" rollback web >/dev/null 2>&1; check "rollback step 1 fails: exits 1" "$?" 1
check "rollback step 1: injected failure was hit" "$([ -e "$T/mvmark" ] && echo yes)" yes
check "rollback step 1: live tree restored" "$(snap "$E/web")" "$LIVE"; check "rollback step 1: previous tree restored" "$(snap "$E/previous/web")" "$PREVS"
check "rollback step 1: no web.swap left" "$([ -e "$E/previous/web.swap" ] && echo yes || echo no)" no
check "rollback step 1: version unchanged" "$(cat "$E/state/web.version")" 2.1.0
fail_mv "$E/previous/web/zz.txt" "$E/web/" "" bash "$R/bin/deploy" rollback web >/dev/null 2>&1; check "rollback step 2 fails: exits 1" "$?" 1
check "rollback step 2: injected failure was hit" "$([ -e "$T/mvmark" ] && echo yes)" yes
check "rollback step 2: live tree restored" "$(snap "$E/web")" "$LIVE"; check "rollback step 2: previous tree restored" "$(snap "$E/previous/web")" "$PREVS"
check "rollback step 2: no web.swap left" "$([ -e "$E/previous/web.swap" ] && echo yes || echo no)" no
fail_mv "$E/previous/web.swap/zz.txt" "$E/previous/web/" "" bash "$R/bin/deploy" rollback web >/dev/null 2>&1; check "rollback step 3 fails: exits 1" "$?" 1
check "rollback step 3: injected failure was hit" "$([ -e "$T/mvmark" ] && echo yes)" yes
check "rollback step 3: live tree restored" "$(snap "$E/web")" "$LIVE"; check "rollback step 3: previous tree restored" "$(snap "$E/previous/web")" "$PREVS"
check "rollback step 3: no web.swap left" "$([ -e "$E/previous/web.swap" ] && echo yes || echo no)" no
check "rollback step 3: version unchanged" "$(cat "$E/state/web.version")" 2.1.0
OUT=$(fail_mv "$E/previous/web.swap/zz.txt" "*" 1 bash "$R/bin/deploy" rollback web 2>&1); check "rollback that cannot be undone: exits 1" "$?" 1
check "unrecoverable rollback prints the failed step" "$(echo "$OUT" | grep -c 'rollback web stopped at step 3 of 3')" 1
check "unrecoverable rollback prints the manual recovery commands" "$(echo "$OUT" | grep -c 'MANUAL RECOVERY NEEDED')" 1
check "unrecoverable rollback: the manual command is in the log" "$(grep -c 'mv .*previous/web/\* .*web.swap/' "$E/state/deploy.log")" 1

two_releases; : >"$T/mvlog"; PATH="$T/shim:$PATH" MV_LOG="$T/mvlog" MV_FAIL_SRC=none MV_FAIL_DST=none bash "$R/bin/deploy" deploy web 2.2.0 --from "$(mk_webx 2.2.0)" >/dev/null 2>&1
INS=$(grep " $E/web/\$" "$T/mvlog" | awk '{n=split($1,a,"/"); print a[n]}' | tail -2 | tr '\n' ' ')
check "index.html and sw.js leave first" "$(grep " $E/previous/web/\$" "$T/mvlog" | awk '{n=split($1,a,"/"); print a[n]}' | head -2 | tr '\n' ' ')" "index.html sw.js "
check "index.html then sw.js come back last" "$INS" "index.html sw.js "
chmod 755 "$EVE_ROOT"
check "no sudo anywhere in the scripts" "$(cat "$R"/bin/* | sed 's/#.*//' | grep -c '\bsudo\b')" 0
# README.md documents the handoff one-liner. It is not installed; the cutover itself is a separate runbook.
HITS=$(grep -R -n -E 'sudo|LaunchDaemon|restart-watcher' "$R" --exclude-dir=.git --exclude-dir=ci-vm --exclude=setup.sh --exclude=guard-install.sh --exclude=test.sh --exclude=README.md || true)
if [ -n "$HITS" ]; then bad "sudo, LaunchDaemon, or restart-watcher outside runner install"; printf '%s\n' "$HITS"; else ok "no sudo, LaunchDaemon, or restart-watcher outside runner install"; fi

echo "== next-version"
N=$T/nv; mkdir -p "$N" && cd "$N" && git init -q . && git config user.email t@t && git config user.name t
mkdir docs && echo a >a.txt && echo d >docs/d.md && git add -A && git commit -qm base && git tag v1.2.3
cat >"$T/gh" <<'SH'
#!/bin/bash
# fake gh: "api repos/R/commits/SHA/pulls --jq ..." -> $PRS (LIST_FAIL=1 -> fails) ; "api repos/R/pulls/N" -> labels of PR N from $LABELS_<N>, unset -> 404 ;
# "api repos/R/issues/N" -> same unless ISSUES_403=1 (the plan job token cannot read issues) ; PULLS_403=1 / READ_FAIL=1 -> 403 like the real gh
fail403() { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
case "$2" in
  */commits/*/pulls) [ "${LIST_FAIL:-}" = 1 ] && fail403; for n in $PRS; do echo "$n"; done;;
  */pulls/*) { [ "${READ_FAIL:-}" = 1 ] || [ "${PULLS_403:-}" = 1 ]; } && fail403; n=${2##*/}; v="LABELS_$n"; [ -n "${!v+x}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; echo "${!v}";;
  */issues/*) { [ "${READ_FAIL:-}" = 1 ] || [ "${ISSUES_403:-}" = 1 ]; } && fail403; n=${2##*/}; v="LABELS_$n"; [ -n "${!v+x}" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; echo "${!v}";;
esac
SH
chmod +x "$T/gh"; export GH="$T/gh"
nv() { ( cd "$N" && git commit -q --allow-empty -m "$1" && S=$(git rev-parse HEAD) && bash "$R/bin/next-version" --repo o/r --sha "$S" 2>/dev/null; echo "rc=$?" ) | tr '\n' ' '; }
nvf() { ( cd "$N" && echo "$RANDOM" >>"$1" && git add -A && git commit -q -m "$2" && S=$(git rev-parse HEAD) && bash "$R/bin/next-version" --repo o/r --sha "$S" 2>/dev/null; echo "rc=$?" ) | tr '\n' ' '; }
export PRS=10; export LABELS_10=""
case "$(nvf a.txt 'code change')" in *"version=1.2.4"*"bump=patch"*"rc=0"*) ok "no label -> patch 1.2.4";; *) bad "no label -> patch: $(nvf a.txt x)";; esac
export LABELS_10="minor"; case "$(nvf a.txt 'code change')" in *"version=1.3.0"*) ok "minor label -> 1.3.0";; *) bad "minor label";; esac
export LABELS_10="major"; case "$(nvf a.txt 'code change')" in *"bump=major"*"rc=1"*) ok "major without security-approved -> fails, no version";; *) bad "major without approval";; esac
export LABELS_10="major,security-approved"; case "$(nvf a.txt 'code change')" in *"version=2.0.0"*"rc=0"*) ok "major + security-approved -> 2.0.0";; *) bad "major approved";; esac
export LABELS_10="no-release"; case "$(nvf a.txt 'code change')" in *"skip=true"*"rc=0"*) ok "no-release label -> skipped";; *) bad "no-release";; esac
export LABELS_10=""; case "$(nvf docs/d.md 'docs only')" in *"skip=true"*"docs-only"*) ok "docs-only commit -> skipped";; *) bad "docs-only";; esac
export PRS=""; export LABELS_77="minor"; case "$(nvf a.txt 'squash of develop (#77)')" in *"version=1.3.0"*) ok "PR number taken from the commit message";; *) bad "PR from message";; esac
export PRS=10; export LABELS_10=""; ( cd "$N" && echo z >>a.txt && git add -A && git commit -q -m tagged && git tag v1.2.9 ); S=$(cd "$N" && git rev-parse HEAD)
case "$(cd "$N" && bash "$R/bin/next-version" --repo o/r --sha "$S" 2>/dev/null | tr '\n' ' ')" in *"version=1.2.9"*"bump=existing"*) ok "already tagged commit -> same version";; *) bad "already tagged";; esac

# every output value is one line (GITHUB_OUTPUT)
export PRS="10 11"; export LABELS_10=""; export LABELS_11=""; OUTF=$T/ghout; : >"$OUTF"; ( cd "$N" && echo "$RANDOM" >>a.txt && git add -A && git commit -q -m "two (#10) (#11)" && GITHUB_OUTPUT="$OUTF" bash "$R/bin/next-version" --repo o/r --sha "$(git rev-parse HEAD)" >/dev/null 2>&1 ); check "GITHUB_OUTPUT: 4 single-line entries" "$(grep -c '^[a-z]*=' "$OUTF")/$(wc -l <"$OUTF" | tr -d ' ')" "4/4"
unset LABELS_11
# regression: the plan job token has no issues: read (issues/N -> 403): the labels must still be read through pulls/N
export PRS=10; export ISSUES_403=1; export LABELS_10="major,security-approved"; case "$(nvf a.txt 'code change')" in *"version=2.0.0"*"bump=major"*"rc=0"*) ok "issues/N 403 -> labels still read via pulls/N (major + approved)";; *) bad "pulls/N path: $(nvf a.txt x)";; esac
unset ISSUES_403
export PRS=10; export PULLS_403=1; export LABELS_10="minor"; case "$(nvf a.txt 'code change')" in *"bump=minor"*"rc=0"*) ok "pulls/N 403 -> falls back to issues/N (minor bump read)";; *) bad "issues fallback: $(nvf a.txt x)";; esac
unset PULLS_403
export PRS=10; export READ_FAIL=1; export LABELS_10="major,security-approved"; case "$(nvf a.txt 'code change')" in *"skip=true"*"rc=1"*) ok "labels of a linked PR unreadable -> fails closed, no tag";; *) bad "fail closed: $(nvf a.txt x)";; esac
export PRS=""; export LABELS_10="major,security-approved"; case "$(nvf a.txt 'squash (#10)')" in *"skip=true"*"rc=1"*) ok "PR list empty, (#10) in the message, label read fails -> fails closed";; *) bad "message PR unreadable: $(nvf a.txt x)";; esac
unset READ_FAIL
export PRS=10; export LIST_FAIL=1; case "$(nvf a.txt 'code change')" in *"skip=true"*"rc=1"*) ok "commits/SHA/pulls call fails -> fails closed";; *) bad "list fail: $(nvf a.txt x)";; esac
unset LIST_FAIL
export PRS=""; case "$(nvf a.txt 'refs another repo (#9999)')" in *"bump=patch"*"rc=0"*) ok "number only in the message and 404 -> ignored";; *) bad "foreign number: $(nvf a.txt x)";; esac
export PRS=""; case "$(nvf a.txt 'direct push without a number')" in *"no PR found"*"rc=0"*) ok "no PR at all -> patch, reason says so";; *) bad "no PR reason: $(nvf a.txt x)";; esac
export PRS="10 11"; export LABELS_10="major,security-approved"; export LABELS_11="no-release"; case "$(nvf a.txt 'two PRs')" in *"skip=true"*"no-release"*"rc=0"*) ok "no-release on one PR wins over major on another";; *) bad "no-release priority: $(nvf a.txt x)";; esac

echo; echo "passed: $PASS  failed: $FAILN"; [ "$FAILN" = 0 ]
