#!/bin/bash
# Tests for bin/pack, bin/deploy and bin/next-version. No root, no network, no sudo: a fake health server and a fake "root watcher" stand in for the host.
# Runs on Linux and macOS (system bash 3.2).   bash tests/test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); R=$(cd "$HERE/.." && pwd)
T=$(mktemp -d); PASS=0; FAILN=0
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; [ -n "${WAT:-}" ] && kill "$WAT" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAILN=$((FAILN + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# ---------- fake host ----------
export EVE_ROOT=$T/root EVE_RESTART_DONE=$T/done EVE_HEALTH_WAIT=4 EVE_RESTART_WAIT=6
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
export EVE_HEALTH_URL=http://127.0.0.1:$PORT/health EVE_UI_URL=http://127.0.0.1:$PORT/ui/ EVE_VERSION_URL=http://127.0.0.1:$PORT/_deploy/version
mkdir -p "$EVE_ROOT/bin" "$EVE_ROOT/web"
cat >"$T/srv.py" <<PY
import http.server, os, json
T="$T"; ROOT="$EVE_ROOT"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        code, body = 404, b""
        if self.path == "/health": code = 503 if os.path.exists(T+"/unhealthy") else 200
        elif self.path.startswith("/ui/"):
            f = ROOT+"/web/index.html"; code = 200 if os.path.exists(f) and b"BAD" not in open(f,"rb").read() else 503
        elif self.path == "/_deploy/version":
            # like the gateway: loopback only (no proxy headers), 404 for everything else; 404 as well for an old binary that has no such endpoint
            if self.headers.get("X-Forwarded-For") or os.path.exists(T+"/noendpoint"): code = 404
            else: code = 200; body = json.dumps({"version": open(T+"/running").read().strip(), "commit": "unknown"}).encode()
        self.send_response(code); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1",$PORT),H).serve_forever()
PY
python3 "$T/srv.py" & SRV=$!
# the "root watcher": when the trigger changes, "restart" the gateway = look at the installed binary
( last=""; while :; do cur=$(cat "$EVE_ROOT/restart.trigger" 2>/dev/null || true)
  if [ -n "$cur" ] && [ "$cur" != "$last" ]; then last=$cur
    if grep -q UNHEALTHY "$EVE_ROOT/bin/gateway" 2>/dev/null; then : >"$T/unhealthy"; else rm -f "$T/unhealthy"; fi
    if grep -q NOENDPOINT "$EVE_ROOT/bin/gateway" 2>/dev/null; then : >"$T/noendpoint"; else rm -f "$T/noendpoint"; fi
    if ! grep -q STALE "$EVE_ROOT/bin/gateway" 2>/dev/null; then "$EVE_ROOT/bin/gateway" -version >"$T/running" 2>/dev/null; fi   # STALE: the old process keeps running (restart did not take)
    printf '%s.%s\n' "$(date +%s)" "$RANDOM" >"$EVE_RESTART_DONE"; fi; sleep 0.2; done ) & WAT=$!
sleep 1

# ---------- helpers: build a gateway / web release with bin/pack ----------
mk_gw() { # version [UNHEALTHY]
  local d=$T/rel-gw-$1; mkdir -p "$d/in"
  printf '#!/bin/sh\n# %s\n[ "$1" = -version ] && echo %s\nexit 0\n' "${2:-ok}" "$1" >"$d/in/gateway"; chmod +x "$d/in/gateway"
  cp "$d/in/gateway" "$d/in/eve-gw"
  bash "$R/bin/pack" gateway --version "$1" --commit 0123456789abcdef0123456789abcdef01234567 --gateway "$d/in/gateway" --eve-gw "$d/in/eve-gw" --out "$d/out" >/dev/null && echo "$d/out"
}
mk_web() { # version [BAD]
  local d=$T/rel-web-$1; mkdir -p "$d/repo"; ( cd "$d/repo" && git init -q . && printf '<html>%s %s</html>\n' "$1" "${2:-good}" >index.html && echo "x" >README.md && mkdir -p tests && echo t >tests/a && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
  bash "$R/bin/pack" web --version "$1" --commit 0123456789abcdef0123456789abcdef01234567 --web-dir "$d/repo" --out "$d/out" >/dev/null && echo "$d/out"
}
D="bash $R/bin/deploy"
res() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" "$EVE_ROOT/state/result.json"; }

echo "== pack"
G1=$(mk_gw 1.0.0); [ -f "$G1/eve-gateway-1.0.0-darwin-arm64.tar.gz" ] && [ -f "$G1/manifest.json" ] && ok "gateway files produced" || bad "gateway files produced"
check "sha256 file matches the tarball" "$(awk '{print $1}' "$G1/eve-gateway-1.0.0-darwin-arm64.tar.gz.sha256")" "$(sha_of "$G1/eve-gateway-1.0.0-darwin-arm64.tar.gz")"
W1=$(mk_web 1.0.0); check "web tar excludes README.md and tests/" "$(tar -tzf "$W1/eve-web-1.0.0.tar.gz" | sort | tr '\n' ' ')" "index.html "
if bash "$R/bin/pack" gateway --version 1.0 --commit x --gateway /nonexistent --out "$T/o" >/dev/null 2>&1; then bad "pack refuses a bad version"; else ok "pack refuses a bad version"; fi

# web tree with a symlink / without index.html is refused
mkdir -p "$T/sl" && ( cd "$T/sl" && git init -q . && echo h >index.html && ln -s /etc/passwd evil && git add -A && git -c user.email=t@t -c user.name=t commit -qm i )
if bash "$R/bin/pack" web --version 1.0.0 --commit 0123456789abcdef0123456789abcdef01234567 --web-dir "$T/sl" --out "$T/slo" >/dev/null 2>&1; then bad "pack refuses a web tree with a symlink"; else ok "pack refuses a web tree with a symlink"; fi

echo "== gateway deploy"
$D deploy gateway 1.0.0 --from "$G1" >"$T/o1" 2>&1; check "first deploy exits 0" "$?" 0
check "state says 1.0.0" "$(cat "$EVE_ROOT/state/gateway.version")" 1.0.0
check "result.json status" "$(res status)" success
check "installed gateway runs" "$("$EVE_ROOT/bin/gateway" -version)" 1.0.0
$D deploy gateway 1.0.0 --from "$G1" >/dev/null 2>&1; check "same version again: exit 0" "$?" 0; check "same version again: unchanged" "$(res status)" unchanged
G2=$(mk_gw 1.1.0)
$D deploy gateway 1.1.0 --from "$G2" >/dev/null 2>&1; check "update exits 0" "$?" 0
check "previous version kept" "$(cat "$EVE_ROOT/state/gateway.previous")" 1.0.0
check "result.json from/to" "$(res from)->$(res to)" "1.0.0->1.1.0"
G3=$(mk_gw 1.2.0 UNHEALTHY)
$D deploy gateway 1.2.0 --from "$G3" >/dev/null 2>&1; check "unhealthy release exits 1" "$?" 1
check "unhealthy release: status rolled-back" "$(res status)" rolled-back
check "unhealthy release: old binary restored" "$("$EVE_ROOT/bin/gateway" -version)" 1.1.0
check "unhealthy release: state unchanged" "$(cat "$EVE_ROOT/state/gateway.version")" 1.1.0
check "unhealthy release: service healthy again" "$(curl -s -o /dev/null -w '%{http_code}' "$EVE_HEALTH_URL")" 200
$D rollback gateway >/dev/null 2>&1; check "rollback exits 0" "$?" 0
check "rollback: now 1.0.0" "$("$EVE_ROOT/bin/gateway" -version)" 1.0.0
check "rollback: state" "$(cat "$EVE_ROOT/state/gateway.version")" 1.0.0
# tampered tarball
G4=$(mk_gw 1.3.0); echo junk >>"$G4/eve-gateway-1.3.0-darwin-arm64.tar.gz"
$D deploy gateway 1.3.0 --from "$G4" >"$T/o4" 2>&1; check "tampered tarball refused" "$?" 1
grep -q "sha256" "$T/o4" && ok "tampered tarball: reason is the sha256" || bad "tampered tarball: reason is the sha256"
check "tampered tarball: nothing changed" "$("$EVE_ROOT/bin/gateway" -version)" 1.0.0
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
mkdir -p "$T/ln/in" && ( cd "$T/ln/in" && printf '#!/bin/sh\nexit 0\n' >gateway && chmod +x gateway && ln -s /etc/passwd eve-gw && tar -czf ../eve-gateway-1.5.1-darwin-arm64.tar.gz gateway eve-gw )
H=$(sha_of "$T/ln/eve-gateway-1.5.1-darwin-arm64.tar.gz"); echo "$H  x" >"$T/ln/eve-gateway-1.5.1-darwin-arm64.tar.gz.sha256"; printf '{"component":"gateway","version":"1.5.1","commit":"x"}\n' >"$T/ln/manifest.json"
$D deploy gateway 1.5.1 --from "$T/ln" >/dev/null 2>&1; check "tar with a symlink refused" "$?" 1
# version endpoint (C4): the new version must be the one that answers; a stale process is rolled back
G6=$(mk_gw 1.6.0 STALE); $D deploy gateway 1.6.0 --from "$G6" >/dev/null 2>&1; check "stale process (wrong version answers) is rolled back" "$?" 1
check "stale process: status" "$(res status)" rolled-back
check "stale process: still on the old version" "$(cat "$EVE_ROOT/state/gateway.version")" 1.0.0
# a release without manifest.json (made by hand) deploys
G7=$(mk_gw 1.7.0); rm "$G7/manifest.json"; $D deploy gateway 1.7.0 --from "$G7" >/dev/null 2>&1; check "release without manifest.json deploys" "$?" 0
# the proxied/tailnet path gets 404 (loopback only)
check "version endpoint refuses a proxied request" "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 100.64.0.1' "$EVE_VERSION_URL")" 404
check "version endpoint answers on loopback" "$(curl -s -o /dev/null -w '%{http_code}' "$EVE_VERSION_URL")" 200
# an older gateway without the endpoint: strict deploy refuses it, restoring it (rollback) works
G8=$(mk_gw 0.9.0 NOENDPOINT); $D deploy gateway 0.9.0 --from "$G8" >/dev/null 2>&1; check "new version without the endpoint fails the strict check" "$?" 1
EVE_VERSION_CHECK=off $D deploy gateway 0.9.0 --from "$G8" >/dev/null 2>&1; check "EVE_VERSION_CHECK=off installs it on health only" "$?" 0
G9=$(mk_gw 0.9.1 UNHEALTHY); $D deploy gateway 0.9.1 --from "$G9" >/dev/null 2>&1
check "restore of an old gateway without the endpoint is accepted" "$(res status)" rolled-back
check "...and the old binary is back" "$("$EVE_ROOT/bin/gateway" -version)" 0.9.0
$D deploy gateway 2.0.0 --from "$(mk_gw 2.0.0)" >/dev/null 2>&1; check "deploy over it works" "$?" 0
# the production plist template turns on startup migrations (BE decision, C5)
grep -q '<key>GW_DB_AUTO_MIGRATE</key><string>true</string>' "$R/deploy/launchd-go/gateway.plist.template" && ok "plist template sets GW_DB_AUTO_MIGRATE=true" || bad "plist template sets GW_DB_AUTO_MIGRATE=true"
grep -q 'GW_DB_AUTO_MIGRATE' "$R/host/setup.sh" && ok "host setup sets GW_DB_AUTO_MIGRATE in the live plist" || bad "host setup sets GW_DB_AUTO_MIGRATE in the live plist"
# a lock left by a running deploy blocks a second one
mkdir "$EVE_ROOT/state/lock"; $D deploy gateway 1.7.0 --from "$G6" >/dev/null 2>&1; check "second deploy while one runs is refused" "$?" 1; rmdir "$EVE_ROOT/state/lock"

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

echo "== next-version"
N=$T/nv; mkdir -p "$N" && cd "$N" && git init -q . && git config user.email t@t && git config user.name t
mkdir docs && echo a >a.txt && echo d >docs/d.md && git add -A && git commit -qm base && git tag v1.2.3
cat >"$T/gh" <<'SH'
#!/bin/bash
# fake gh: "api repos/R/commits/SHA/pulls --jq ..." -> $PRS ; "api repos/R/pulls/N" -> labels of PR N from $LABELS_<N> ;
# "api repos/R/issues/N" -> same unless ISSUES_403=1 (the plan job token cannot read issues) ; READ_FAIL=1 -> both fail
case "$2" in
  */commits/*/pulls) for n in $PRS; do echo "$n"; done;;
  */pulls/*) [ "${READ_FAIL:-}" = 1 ] || [ "${PULLS_403:-}" = 1 ] && exit 1; n=${2##*/}; v="LABELS_$n"; [ -n "${!v+x}" ] || exit 1; echo "${!v}";;
  */issues/*) [ "${READ_FAIL:-}" = 1 ] || [ "${ISSUES_403:-}" = 1 ] && exit 1; n=${2##*/}; v="LABELS_$n"; [ -n "${!v+x}" ] || exit 1; echo "${!v}";;
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

# regression: the plan job token has no issues: read (issues/N -> 403): the labels must still be read through pulls/N
export PRS=10; export ISSUES_403=1; export LABELS_10="major,security-approved"; case "$(nvf a.txt 'code change')" in *"version=2.0.0"*"rc=0"*) ok "issues/N 403 -> labels still read via pulls/N (major + approved)";; *) bad "pulls/N path: $(nvf a.txt x)";; esac
unset ISSUES_403
export PRS=10; export PULLS_403=1; export LABELS_10="minor"; case "$(nvf a.txt 'code change')" in *"version=1."*"rc=0"*) ok "pulls/N unreadable -> falls back to issues/N";; *) bad "issues fallback";; esac
unset PULLS_403
export PRS=10; export READ_FAIL=1; export LABELS_10="major,security-approved"; case "$(nvf a.txt 'code change')" in *"skip=true"*"rc=1"*) ok "labels of a linked PR unreadable -> fails closed, no tag";; *) bad "fail closed: $(nvf a.txt x)";; esac
unset READ_FAIL
export PRS=""; case "$(nvf a.txt 'refs another repo (#9999)')" in *"rc=0"*) ok "number only in the commit message and unreadable -> ignored";; *) bad "foreign number";; esac

echo; echo "passed: $PASS  failed: $FAILN"; [ "$FAILN" = 0 ]
