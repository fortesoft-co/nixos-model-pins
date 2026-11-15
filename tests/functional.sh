#!/usr/bin/env bash
# Hermetic functional test: the runtime's ensure -> seal -> audit cycle
# against a throwaway dataDir with a file:// fixture. No network, no nix
# build, no root — seal degrades gracefully when not root (skips chown),
# so the full store law is exercisable as a regular user: placement,
# links, sidecars, relink, drift quarantine, audit, and the read-only
# workflow namespace.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
rt="$here/../tools/download_runtime.py"
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  for f in "$work"/log*; do
    [ -f "$f" ] && { echo "── $f"; cat "$f"; } >&2
  done
  exit 1
}
ok() { echo "ok: $*"; }

# ── fixture + manifests ─────────────────────────────────────────────────
printf 'model-pins functional fixture v1\n' > "$work/upstream.gguf"
sha=$(sha256sum "$work/upstream.gguf" | cut -d' ' -f1)

python3 - "$work" "$sha" <<'PYEOF'
import json, os, sys
work, sha = sys.argv[1], sys.argv[2]
url = "file://" + work + "/upstream.gguf"
def entry(**kw):
    base = {"id": "fixture", "kind": None, "dest": "llm/fixture.gguf",
            "sha256": sha, "tokenFile": None, "unzipInto": None,
            "name": None, "fallbackUrls": [], "urls": [url], "legacy": False,
            "provenance": {"source": "huggingface", "repo": "example/fixture",
                           "rev": "0" * 40, "file": "fixture.gguf"}}
    base.update(kw)
    return base
store_entry = entry()
wf_entry = entry(id="ns-one", kind="workflow", dest="managed/pins/ns-one",
                 name="fixture.gguf")
for fname, rows in (("m1.json", [store_entry]),
                    ("m2.json", [store_entry, wf_entry]),
                    ("m3.json", [store_entry])):
    with open(os.path.join(work, fname), "w") as f:
        json.dump(rows, f, indent=1)
PYEOF

dd="$work/data"
blob_name="fixture--$sha.gguf"
blob="$dd/store/$blob_name"
link="$dd/llm/fixture.gguf"

# ── 1. happy path: ensure stages + promotes, seal places + links ────────
python3 "$rt" ensure --manifest "$work/m1.json" --dataDir "$dd" --jobs 1 >"$work/log1" 2>&1
grep -q "promote(fetch) fixture" "$work/log1" || fail "ensure did not promote the fetch"
python3 "$rt" seal --manifest "$work/m1.json" --dataDir "$dd" --link-owner "$(id -un):$(id -gn)" >"$work/log2" 2>&1
grep -q "PLACED" "$work/log2" || fail "seal did not place the blob"
[ -f "$blob" ] || fail "blob missing"
[ "$(stat -c %a "$blob")" = "444" ] || fail "blob not 0444"
[ -L "$link" ] || fail "link missing"
[ "$(readlink "$link")" = "$blob" ] || fail "link target wrong"
[ -f "$blob.pin.json" ] || fail "sidecar missing"
grep -q "$sha" "$blob.pin.json" || fail "sidecar does not carry the digest"
[ -f "$dd/store/README.md" ] || fail "store README missing"
ok "happy path: blob 0444 + link + sidecar + README"

# ── 2. relink: link deleted, blob intact → ensure relinks, no refetch ───
rm "$link"
python3 "$rt" ensure --manifest "$work/m1.json" --dataDir "$dd" --jobs 1 >"$work/log3" 2>&1
[ -L "$link" ] || fail "link not recreated by ensure"
grep -q "LINKED" "$work/log3" || fail "no relink note in ensure log"
ok "relink from existing blob, no refetch"

# ── 3. drift: impostor real file at dest → quarantined, link restored ──
# (rm first: writing through the link would hit the 0444 blob — the
# store law refusing writes through links is the point)
rm "$link"
printf 'impostor bytes\n' > "$link"
python3 "$rt" ensure --manifest "$work/m1.json" --dataDir "$dd" --jobs 1 >"$work/log4" 2>&1
[ -L "$link" ] || fail "link not restored after drift"
[ "$(readlink "$link")" = "$blob" ] || fail "restored link targets wrong"
ls "$dd/.pinwork/quarantine/"fixture-*.drift >/dev/null 2>&1 || fail "impostor not quarantined"
ok "drift: impostor parked in quarantine, link restored"

# ── 4. audit: ensure + full sweep passes clean ──────────────────────────
python3 "$rt" audit --manifest "$work/m1.json" --dataDir "$dd" --jobs 1 >"$work/log5" 2>&1
ok "audit sweep passes"

# ── 5. workflow namespace: single-file pin installs read-only, drop removes ──
python3 "$rt" ensure --manifest "$work/m2.json" --dataDir "$dd" --wfpins managed/pins --jobs 1 >"$work/log6" 2>&1
wf="$dd/managed/pins/ns-one/fixture.gguf"
[ -f "$wf" ] || fail "workflow pin not installed"
[ "$(stat -c %a "$wf")" = "444" ] || fail "workflow pin not 0444"
python3 "$rt" ensure --manifest "$work/m3.json" --dataDir "$dd" --wfpins managed/pins --jobs 1 >"$work/log7" 2>&1
[ ! -e "$wf" ] || fail "dropped workflow pin not removed"
ok "workflow namespace: read-only install + drop removal"

# ── 6. token: sent as a header, never on curl's argv ───────────────────
# A localhost server records the Authorization header; a curl shim on
# PATH records argv. The token must reach the server and not the argv.
tok="test-token-$$"
printf '%s\n' "$tok" > "$work/token"
printf 'token-gated fixture\n' > "$work/gated.gguf"
gsha=$(sha256sum "$work/gated.gguf" | cut -d' ' -f1)
mkdir -p "$work/shim"
real_curl=$(command -v curl)
cat > "$work/shim/curl" <<EOF
#!/usr/bin/env sh
printf '%s\n' "\$*" >> "$work/curl-argv"
exec "$real_curl" "\$@"
EOF
chmod +x "$work/shim/curl"
python3 - "$work" > "$work/port" 2>"$work/log-http" <<'PYEOF' &
import http.server, os, sys
work = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(work, "seen-auth"), "a") as f:
            f.write((self.headers.get("Authorization") or "") + "\n")
        body = open(os.path.join(work, "gated.gguf"), "rb").read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PYEOF
http_pid=$!
trap 'kill $http_pid 2>/dev/null || true; chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/port" ] && break; sleep 0.2; done
port=$(cat "$work/port")
[ -n "$port" ] || fail "test http server did not start"
python3 - "$work" "$gsha" "$port" <<'PYEOF'
import json, os, sys
work, sha, port = sys.argv[1], sys.argv[2], sys.argv[3]
row = {"id": "gated", "kind": None, "dest": "llm/gated.gguf", "sha256": sha,
       "tokenFile": os.path.join(work, "token"), "unzipInto": None,
       "name": None, "fallbackUrls": [], "legacy": False, "provenance": {},
       "urls": [f"http://127.0.0.1:{port}/gated.gguf"]}
with open(os.path.join(work, "m4.json"), "w") as f:
    json.dump([row], f)
PYEOF
PATH="$work/shim:$PATH" python3 "$rt" ensure --manifest "$work/m4.json" --dataDir "$dd" --jobs 1 >"$work/log8" 2>&1
grep -q "promote(fetch) gated" "$work/log8" || fail "token-gated fetch did not stage"
grep -qx "Bearer $tok" "$work/seen-auth" || fail "server did not receive the bearer token"
[ -s "$work/curl-argv" ] || fail "curl shim was not used"
! grep -q "$tok" "$work/curl-argv" || fail "token leaked onto curl argv"
ok "token: bearer header delivered, absent from argv"

# ── 6b. token scoping: a mirror never receives the token ───────────────
# Primary URL dead, mirror = the test server: the fetch succeeds through
# the mirror, which must see no Authorization header.
: > "$work/seen-auth"
python3 - "$work" "$gsha" "$port" <<'PYEOF'
import json, os, sys
work, sha, port = sys.argv[1], sys.argv[2], sys.argv[3]
row = {"id": "mirrored", "kind": None, "dest": "llm/mirrored.gguf", "sha256": sha,
       "tokenFile": os.path.join(work, "token"), "unzipInto": None,
       "name": None, "legacy": False, "provenance": {},
       "urls": ["file://" + os.path.join(work, "gone.gguf"),
                f"http://127.0.0.1:{port}/gated.gguf"]}
row["fallbackUrls"] = row["urls"][1:]
with open(os.path.join(work, "m6.json"), "w") as f:
    json.dump([row], f)
PYEOF
python3 "$rt" ensure --manifest "$work/m6.json" --dataDir "$dd" --jobs 1 >"$work/log8b" 2>&1
grep -q "promote(fetch) mirrored" "$work/log8b" || fail "mirror fetch did not stage"
[ -s "$work/seen-auth" ] || fail "mirror was not contacted"
! grep -q "Bearer" "$work/seen-auth" || fail "token leaked to a mirror"
ok "token scoping: mirror fetched without the token"

# ── 6c. token scoping rules: first-party https hosts only ──────────────
python3 - "$rt" "$work/token" <<'PYEOF' || fail "token scoping rules"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rt", sys.argv[1])
rt = importlib.util.module_from_spec(spec); spec.loader.exec_module(rt)
tf = sys.argv[2]
def pin(t, urls):
    return rt.Pin({"id": "x", "tokenFile": tf, "urls": urls, "transport": {"type": t}})
cv = pin("civitai", [])
hf = pin("huggingface", [])
cases = [
    (cv, "https://civitai.red/api/download/models/1", True),
    (cv, "https://civitai.com/api/download/models/1", True),
    (cv, "https://www.civitai.com/x", True),
    (cv, "http://civitai.com/x", False),
    (cv, "https://evilcivitai.red/x", False),
    (cv, "https://civitai.red.example.net/x", False),
    (cv, "https://mirror.example.net/x", False),
    (hf, "https://huggingface.co/r/resolve/0/f", True),
    (hf, "https://civitai.com/x", False),
    (pin("url", ["https://a.example/f", "https://b.example/f"]), "https://a.example/f", True),
    (pin("url", ["https://a.example/f", "https://b.example/f"]), "https://b.example/f", False),
]
bad = [(p.transport["type"], u) for p, u, want in cases if (p.token_for(u) is not None) != want]
if bad:
    print("wrong token decision:", bad); sys.exit(1)
PYEOF
ok "token scoping rules: first-party https only, primary-only for url rows"

# ── 7. unzipInto: extract, detect drift, re-extract ─────────────────────
python3 - "$work" <<'PYEOF'
import os, sys, zipfile
work = sys.argv[1]
with zipfile.ZipFile(os.path.join(work, "bundle.zip"), "w") as z:
    z.writestr("a.txt", "alpha\n")
    z.writestr("sub/b.txt", "beta\n")
PYEOF
zsha=$(sha256sum "$work/bundle.zip" | cut -d' ' -f1)
python3 - "$work" "$zsha" <<'PYEOF'
import json, os, sys
work, sha = sys.argv[1], sys.argv[2]
row = {"id": "bundle", "kind": None, "dest": "bundles/bundle.zip", "sha256": sha,
       "tokenFile": None, "unzipInto": "bundles/bundle", "name": None,
       "fallbackUrls": [], "legacy": True, "provenance": {},
       "urls": ["file://" + os.path.join(work, "bundle.zip")]}
with open(os.path.join(work, "m5.json"), "w") as f:
    json.dump([row], f)
PYEOF
ub="$dd/bundles/bundle"
python3 "$rt" ensure --manifest "$work/m5.json" --dataDir "$dd" --jobs 1 >"$work/log9" 2>&1
[ "$(cat "$ub/sub/b.txt")" = "beta" ] || fail "bundle not extracted"
grep -q "  sub/b.txt$" "$ub/.unzipped.sha256" || fail "extraction manifest missing member"
python3 "$rt" ensure --manifest "$work/m5.json" --dataDir "$dd" --jobs 1 >"$work/log10" 2>&1
! grep -q "drifted" "$work/log10" || fail "clean bundle reported as drifted"
printf 'tampered\n' > "$ub/sub/b.txt"
python3 "$rt" ensure --manifest "$work/m5.json" --dataDir "$dd" --jobs 1 >"$work/log11" 2>&1
grep -q "drifted" "$work/log11" || fail "bundle drift not detected"
[ "$(cat "$ub/sub/b.txt")" = "beta" ] || fail "drifted bundle not re-extracted"
ok "unzipInto: extract, verify clean, re-extract on drift"

# ── 8-11. transports: platform tools first, curl fallback ──────────────
# Stub `hf` / `civitai` on PATH log argv and their token variable, then
# deliver $STUB_SRC (STUB_MODE=fail makes them exit 1). Each case's curl
# URL tells the routes apart: "dead" never resolves, so a placed blob
# proves the platform tool delivered it.
mkdir -p "$work/tools"
cat > "$work/tools/hf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG.hf-argv"
printf 'HF_TOKEN=%s\n' "${HF_TOKEN:-}" >> "$STUB_LOG.hf-env"
[ "${STUB_MODE:-ok}" = fail ] && exit 1
# hf download <repo> <file> --revision <rev> --local-dir <dir>
file=$3 dir=
while [ $# -gt 0 ]; do [ "$1" = --local-dir ] && dir=$2; shift; done
mkdir -p "$dir/$(dirname "$file")" && cp "$STUB_SRC" "$dir/$file"
EOF
cat > "$work/tools/civitai" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG.civitai-argv"
printf 'CIVITAI_TOKEN=%s\n' "${CIVITAI_TOKEN:-}" >> "$STUB_LOG.civitai-env"
printf 'CIVITAI_BASE_URL=%s\n' "${CIVITAI_BASE_URL:-}" >> "$STUB_LOG.civitai-env"
[ "${STUB_MODE:-ok}" = fail ] && exit 1
out=
while [ $# -gt 0 ]; do [ "$1" = --out ] && out=$2; shift; done
cp "$STUB_SRC" "$out"
EOF
chmod +x "$work/tools/hf" "$work/tools/civitai"

printf 'transport fixture\n' > "$work/model.bin"
msha=$(sha256sum "$work/model.bin" | cut -d' ' -f1)
dead="file://$work/does-not-exist.bin"
live="file://$work/model.bin"

# transport_case <name> <transport-json> <url> <with-token:0|1>
transport_case() {
  python3 - "$work" "$msha" "$1" "$2" "$3" "$4" <<'PYEOF'
import json, os, sys
work, sha, name, transport, url, with_token = sys.argv[1:]
row = {"id": name, "kind": None, "dest": f"llm/{name}.bin", "sha256": sha,
       "tokenFile": os.path.join(work, "token") if with_token == "1" else None,
       "unzipInto": None, "name": None, "fallbackUrls": [], "legacy": False,
       "provenance": {}, "urls": [url], "transport": json.loads(transport)}
with open(os.path.join(work, f"t-{name}.json"), "w") as f:
    json.dump([row], f)
PYEOF
  PATH="$work/tools:$PATH" STUB_SRC="$work/model.bin" STUB_LOG="$work/stub-$1" \
    python3 "$rt" ensure --manifest "$work/t-$1.json" --dataDir "$work/d-$1" --jobs 1 \
    >"$work/log-$1" 2>&1 || true
  python3 "$rt" seal --manifest "$work/t-$1.json" --dataDir "$work/d-$1" >>"$work/log-$1" 2>&1 || true
}
placed() { [ -L "$work/d-$1/llm/$1.bin" ] && [ -f "$work/d-$1/store/$1--$msha.bin" ]; }

hf_t='{"type": "huggingface", "repo": "example/fixture", "rev": "0123abc", "file": "sub/model.bin"}'
transport_case hf "$hf_t" "$dead" 1
placed hf || fail "hf transport did not deliver"
grep -q -- "download example/fixture sub/model.bin --revision 0123abc --local-dir" "$work/stub-hf.hf-argv" \
  || fail "hf not called with the pinned repo/file/revision"
! grep -q "$tok" "$work/stub-hf.hf-argv" || fail "token leaked onto hf argv"
grep -qx "HF_TOKEN=$tok" "$work/stub-hf.hf-env" || fail "hf did not get HF_TOKEN"
ok "hf: pinned download via hf, token via env only"

STUB_MODE=fail transport_case hffail "$hf_t" "$live" 0
placed hffail || fail "hf failure did not fall back to curl"
grep -q "falling back to curl" "$work/log-hffail" || fail "no fallback note after hf failure"
ok "hf: failure falls back to curl"

cv_t='{"type": "civitai", "versionId": "42", "fileId": 7}'
transport_case cv "$cv_t" "$dead" 1
placed cv || fail "civitai transport did not deliver"
grep -q -- "download --no-update-check --version 42 --out .* --force --file 7" "$work/stub-cv.civitai-argv" \
  || fail "civitai CLI not pinned with --version / --file"
! grep -q "$tok" "$work/stub-cv.civitai-argv" || fail "token leaked onto civitai argv"
grep -qx "CIVITAI_TOKEN=$tok" "$work/stub-cv.civitai-env" || fail "civitai did not get CIVITAI_TOKEN"
grep -qx "CIVITAI_BASE_URL=https://civitai.red" "$work/stub-cv.civitai-env" || fail "civitai CLI not pointed at civitai.red"
ok "civitai: token -> CLI on civitai.red pinned to the version, token via env only"

transport_case cvanon "$cv_t" "$live" 0
placed cvanon || fail "tokenless civitai did not download over curl"
[ ! -e "$work/stub-cvanon.civitai-argv" ] || fail "civitai CLI invoked without a token"
ok "civitai: no token -> public endpoint over curl, CLI untouched"

echo "FUNCTIONAL TEST PASSED"
