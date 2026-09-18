#!/usr/bin/env bash
#
# deploy_site.sh — mesonx.ai deploy pipeline
#
#   1. Commit & push source to https://github.com/MesonX-ai/mesonx.ai.git
#      (initializes the repo on first run).
#   2. Upload ONLY newly added / edited files to the EXISTING mesonx.ai
#      folder on GoDaddy hosting over FTP.
#      New + edited files are detected by a SHA-256 checksum diff against the
#      last deployment (manifest at .deploy/last-deploy-manifest.sha256, with a
#      copy of the manifest also stored on the server as
#      mesonxai-deploy-manifest.sha256 so a fresh clone can still diff).
#
#   IMPORTANT — the upload target is the EXISTING mesonx.ai folder on the
#   server (resolved from the "MesonX.ai" entry's path in ftp-config.json).
#   This script NEVER creates the base folder or anything outside it; only
#   sub-folders INSIDE it (e.g. assets/) get created while uploading.
#
# Usage:
#   ./deploy_site.sh                  # commit + push + upload
#   ./deploy_site.sh -m "my message"  # custom commit message
#   ./deploy_site.sh --dry-run        # upload preview only (no FTP writes, no push)
#   ./deploy_site.sh --skip-git       # upload only (no commit/push)
#   ./deploy_site.sh --skip-build    # no build step (plain static site: no-op check)
#   ./deploy_site.sh --skip-upload    # git only
#   ./deploy_site.sh --force          # ignore checksum manifest; upload everything
#
# Credentials come from the "MesonX.ai" entry in ftp-config.json (project dir
# first, then parent dir) or from FTP_HOST / FTP_USER / FTP_PASS / FTP_PORT.
# NOTE: the shared ftp-config.json is not strict JSON (it has a missing
# comma between two entries), so it is parsed with a tolerant regex-based
# reader, not json.load (which throws "Expecting ',' delimiter").

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

GIT_REMOTE_URL="${GIT_REMOTE_URL:-https://github.com/MesonX-ai/mesonx.ai.git}"

# ---------------------------------------------------------------- args ----
COMMIT_MSG=""
DRY_RUN=false
SKIP_GIT=false
SKIP_BUILD=false
SKIP_UPLOAD=false
FORCE=false

usage() {
  sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message)   COMMIT_MSG="${2:?--message requires a value}"; shift 2 ;;
    --dry-run)      DRY_RUN=true; SKIP_UPLOAD=true; shift ;;
    -f|--force)     FORCE=true; shift ;;
    --skip-git)     SKIP_GIT=true; shift ;;
    --skip-build)   SKIP_BUILD=true; shift ;;
    --skip-upload)  SKIP_UPLOAD=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1 (see $0 --help)" >&2; exit 1 ;;
  esac
done

# ------------------------------------------------------------------ logs ----
BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; NC=$'\033[0m'
log()  { printf '%s[MesonX.ai]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()   { printf '%s[MesonX.ai]%s ✓ %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[MesonX.ai]%s ⚠ %s\n' "$YELLOW" "$NC" "$*"; }
fail() { printf '%s[MesonX.ai]%s ✗ %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1 (install it and re-run)."
}

require_cmd git
if [[ -f package.json ]]; then
  require_cmd npm
fi
require_cmd lftp
require_cmd rsync
require_cmd python3

# ------------------------------------------------------ checksum helpers ----
# Build a "<rel>\t<sha256>" manifest for every DEPLOYABLE file under $1
# (excluding .git/, .deploy/, out/, node_modules/, dev scripts and the remote
# manifest copy itself), writing it to $2.
hash_out() {
  OUT_DIR="$1" TMP_MANIFEST="$2" SKIP_NAME="$3" python3 - <<'PY'
import hashlib, os
from pathlib import Path
out = Path(os.environ["OUT_DIR"])
skip = os.environ.get("SKIP_NAME", "")
EXCLUDE_PREFIXES = (".git/", ".deploy/", "out/", "node_modules/", ".vscode/", ".idea/")
EXCLUDE_FILES = {
    "deploy_site.sh", "local_start.sh", ".gitignore", ".gitattributes",
    "mesonxai-deploy-manifest.sha256", "mesonsoft-deploy-manifest.sha256",
}
rows = []
for p in sorted(x for x in out.rglob("*") if x.is_file()):
    rel = p.relative_to(out).as_posix()
    if rel == skip or rel in EXCLUDE_FILES or rel.endswith(".DS_Store"):
        continue
    if rel.startswith(EXCLUDE_PREFIXES):
        continue
    rows.append(f"{rel}\t{hashlib.sha256(p.read_bytes()).hexdigest()}")
Path(os.environ["TMP_MANIFEST"]).write_text(
    "\n".join(rows) + ("\n" if rows else ""), encoding="utf-8"
)
PY
}

# Compare the previous-deploy manifest against the local one and write the
# sorted list of new/edited files (checksum differs or file is new) to $3.
diff_changed() {
  TMP_LOCAL="$1" TMP_PREV="$2" TMP_CHANGED="$3" python3 - <<'PY'
import os
from pathlib import Path

def load(path):
    out = {}
    p = Path(path)
    if not p.exists():
        return out
    for line in p.read_text().splitlines():
        if not line:
            continue
        rel, h = line.split("\t", 1)
        out[rel] = h
    return out

local = load(os.environ["TMP_LOCAL"])
prev = load(os.environ["TMP_PREV"])
changed = sorted(rel for rel, h in local.items() if prev.get(rel) != h)
Path(os.environ["TMP_CHANGED"]).write_text(
    "\n".join(changed) + ("\n" if changed else ""), encoding="utf-8"
)
print(f"local={len(local)} changed/new={len(changed)} unchanged={len(local) - len(changed)}")
PY
}

# ---------------------------------------------------------------- 1. git ----
if [[ "$SKIP_GIT" == true ]]; then
  log "Git step skipped (--skip-git)."
else
  # Initialize the repo on first run and point it at GitHub.
  if [[ ! -d .git ]]; then
    log "No git repository found — initializing and setting remote $GIT_REMOTE_URL ..."
    git init -b main
    git remote add origin "$GIT_REMOTE_URL"
    ok "Repository initialized on branch main."
  else
    # Make sure the origin remote points at the expected GitHub URL.
    if git remote get-url origin >/dev/null 2>&1; then
      CURRENT_URL="$(git remote get-url origin)"
      if [[ "$CURRENT_URL" != "$GIT_REMOTE_URL" ]]; then
        log "Updating origin remote: $CURRENT_URL -> $GIT_REMOTE_URL"
        git remote set-url origin "$GIT_REMOTE_URL"
      fi
    else
      git remote add origin "$GIT_REMOTE_URL"
    fi
  fi

  log "Committing and pushing source to GitHub..."
  git add -A
  if git diff --cached --quiet; then
    ok "Nothing new to commit."
  else
    MSG="${COMMIT_MSG:-deploy: $(date '+%Y-%m-%d %H:%M:%S')}"
    git commit -m "$MSG"
    ok "Committed: $MSG"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] Skipping git push."
  else
    # Push; on the very first push, set upstream tracking.
    if ! git push origin HEAD; then
      warn "Push to origin HEAD failed — retrying with upstream set."
      git push -u origin main
    fi
    ok "Source pushed to $GIT_REMOTE_URL"
  fi
fi

# ------------------------------------------------------------- 2. build ----
# mesonx.ai is a plain static site (index.html + liquid-glass.js + assets/
# in the project root). If a package.json with a build script exists (e.g. a
# future Next.js migration), build it into out/; otherwise deploy the project
# root directly (STATIC_SRC=.).
STATIC_SRC="$PROJECT_DIR"
if [[ -f package.json ]] && grep -q '"build"' package.json 2>/dev/null; then
  if [[ ! -d node_modules ]]; then
    log "node_modules missing — running npm install ..."
    npm install
  fi

  if [[ "$SKIP_BUILD" == true ]]; then
    log "Build step skipped (--skip-build) — using existing out/."
  else
    log "package.json with build script found — building static export (npm run build -> out/)..."
    npm run build
  fi
  [[ -f out/index.html ]] || fail "out/index.html missing — static export did not run. Aborting."
  ok "Static build is ready (out/)."
  STATIC_SRC="$PROJECT_DIR/out"
else
  if [[ "$SKIP_BUILD" == true ]]; then
    log "Build step skipped (--skip-build) — static site needs no build."
  else
    log "No package.json build script — plain static site, nothing to build."
  fi
  [[ -f index.html ]] || fail "index.html missing in $PROJECT_DIR — nothing to deploy. Aborting."
  ok "Static source is ready (project root: index.html + assets/)."
fi

# ---------------------------------------- 3. dry-run: preview upload ----
if [[ "$DRY_RUN" == true ]]; then
  log "Calculating upload preview (no FTP contact — commit was already made locally)."
  OUT_DIR="$STATIC_SRC"
  REMOTE_MANIFEST_NAME="mesonxai-deploy-manifest.sha256"
  CACHE_MANIFEST="$PROJECT_DIR/.deploy/last-deploy-manifest.sha256"
  TMP_DIR="$(mktemp -d)"
  LOCAL_MANIFEST="$TMP_DIR/local-manifest.sha256"
  PREV_MANIFEST="$TMP_DIR/prev-manifest.sha256"
  CHANGED_LIST="$TMP_DIR/changed-files.txt"
  trap 'rm -rf "$TMP_DIR"' EXIT

  hash_out "$OUT_DIR" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST_NAME"
  [[ -s "$CACHE_MANIFEST" ]] && cp "$CACHE_MANIFEST" "$PREV_MANIFEST"
  diff_changed "$LOCAL_MANIFEST" "$PREV_MANIFEST" "$CHANGED_LIST"
  preview_count="$(wc -l < "$CHANGED_LIST" | tr -d ' ')"
  if [[ "$preview_count" == "0" ]]; then
    ok "No new or edited files vs the last deploy — nothing would be uploaded."
  else
    log "Would upload $preview_count new/edited file(s):"
    sed 's/^/  ↑ /' "$CHANGED_LIST"
  fi
  ok "Dry run complete."
  exit 0
fi

# ----------------------------------------------------------- 3. upload ----
if [[ "$SKIP_UPLOAD" == true ]]; then
  warn "Upload step skipped (--skip-upload)."
  ok "Done (no FTP upload performed)."
  exit 0
fi

# 3a. Credentials
FTP_HOST="${FTP_HOST:-}"
FTP_USER="${FTP_USER:-}"
FTP_PASS="${FTP_PASS:-}"
FTP_PORT="${FTP_PORT:-21}"
FTP_PATH="${FTP_PATH:-}"

if [[ -z "$FTP_HOST" || -z "$FTP_USER" || -z "$FTP_PASS" ]]; then
  FTP_CONFIG="${FTP_CONFIG:-}"
  if [[ -z "$FTP_CONFIG" ]]; then
    for cand in "$PROJECT_DIR/ftp-config.json" "$PROJECT_DIR/../ftp-config.json"; do
      if [[ -f "$cand" ]]; then FTP_CONFIG="$cand"; break; fi
    done
  fi
  [[ -f "$FTP_CONFIG" ]] || fail "ftp-config.json not found and FTP_HOST/FTP_USER/FTP_PASS not set."

  CREDS="$(FTP_CONFIG="$FTP_CONFIG" python3 - <<'PY'
import os, re
raw = open(os.environ["FTP_CONFIG"], encoding="utf-8").read()
# Tolerantly split the loose array into {...} blocks (shared ftp-config.json
# is missing a comma between two entries, so json.load fails).
blocks = re.findall(r"\{[^{}]*\}", raw, re.S)
want = "mesonx.ai"
found = None
fallback = None
for b in blocks:
    name = (re.search(r'"name"\s*:\s*"([^"]*)"', b) or [None, ""])[1]
    if name.lower() == want:
        found = b
        break
    if fallback is None and name.lower() == "mesonsoft":
        fallback = b
if found is None:
    found = fallback  # legacy fallback: root FTP user
if found:
    def g(k, d=""):
        m = re.search(r'"%s"\s*:\s*(?:"([^"]*)"|(\d+))' % k, found)
        return (m.group(1) if m.group(1) is not None else m.group(2)) if m else d
    print(f"{g('host')}\t{g('port', '21')}\t{g('username')}\t{g('password')}\t{g('path', '')}")
PY
)"
  [[ -n "$CREDS" ]] || fail "No \"MesonX.ai\" (or legacy \"Mesonsoft\") entry found in $FTP_CONFIG."
  [[ -n "$FTP_HOST" ]] || FTP_HOST="$(echo "$CREDS" | cut -f1)"
  [[ "$FTP_PORT" == "21" && -n "$(echo "$CREDS" | cut -f2)" ]] && FTP_PORT="$(echo "$CREDS" | cut -f2)"
  [[ -n "$FTP_USER" ]] || FTP_USER="$(echo "$CREDS" | cut -f3)"
  [[ -n "$FTP_PASS" ]] || FTP_PASS="$(echo "$CREDS" | cut -f4)"
  FTP_PATH="$(echo "$CREDS" | cut -f5)"
fi
[[ -n "$FTP_HOST" && -n "$FTP_USER" && -n "$FTP_PASS" ]] || fail "Incomplete FTP credentials (host/user/pass)."

# 3b. Resolve the upload target: the EXISTING mesonx.ai folder on the server
#     (the "path" of the "MesonX.ai" entry in ftp-config.json, here "mesonx.ai").
#     Per the header contract we NEVER create the base folder or anything
#     outside it — only sub-folders INSIDE it (e.g. assets/) may be created by
#     the mirror. FTP_PATH may be "mesonx.ai", "/public_html/mesonx.ai", or
#     empty (already inside it) — normalize to the last two path components.
OUT_DIR="$STATIC_SRC"
REMOTE_MANIFEST_NAME="mesonxai-deploy-manifest.sha256"
REMOTE_BASE="$(echo "${FTP_PATH:-mesonx.ai}" | sed -e 's#^/public_html/##' -e 's#^/*##' -e 's#/*$##')"
[[ -n "$REMOTE_BASE" ]] || REMOTE_BASE="mesonx.ai"
if ! lftp -u "$FTP_USER","$FTP_PASS" "$FTP_HOST" -p "$FTP_PORT" \
    -e "set ftp:passive-mode on; set ssl:verify-certificate no; set cmd:fail-exit on; cd $REMOTE_BASE; cls; quit" \
    >/dev/null 2>&1; then
  fail "Could not cd into '$REMOTE_BASE' on $FTP_HOST (login failed or the existing mesonx.ai folder is not reachable). Create it once on the server — this script never creates the base folder itself."
fi
ok "Remote target: existing folder '$REMOTE_BASE' (uploading only inside it; base folder never created by this script)."

# 3c. Checksums + diff
CACHE_DIR="$PROJECT_DIR/.deploy"
CACHE_MANIFEST="$CACHE_DIR/last-deploy-manifest.sha256"
mkdir -p "$CACHE_DIR"

TMP_DIR="$(mktemp -d)"
LOCAL_MANIFEST="$TMP_DIR/local-manifest.sha256"
PREV_MANIFEST="$TMP_DIR/prev-manifest.sha256"
CHANGED_LIST="$TMP_DIR/changed-files.txt"
DELTA_DIR="$TMP_DIR/upload-delta"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Hashing local source ($OUT_DIR) (SHA-256)..."
hash_out "$OUT_DIR" "$LOCAL_MANIFEST" "$REMOTE_MANIFEST_NAME"

if [[ "$FORCE" == true ]]; then
  log "--force: ignoring previous checksum manifest (all files will be uploaded)."
elif [[ -s "$CACHE_MANIFEST" ]]; then
  cp "$CACHE_MANIFEST" "$PREV_MANIFEST"
  log "Using local manifest from last deploy ($(wc -l < "$PREV_MANIFEST" | tr -d ' ') files)."
else
  log "No local manifest — trying to fetch $REMOTE_MANIFEST_NAME from server ..."
  if lftp -u "$FTP_USER","$FTP_PASS" "$FTP_HOST" -p "$FTP_PORT" \
      -e "set ftp:passive-mode on; set ssl:verify-certificate no; set cmd:fail-exit no; cd $REMOTE_BASE; get $REMOTE_MANIFEST_NAME -o $PREV_MANIFEST; quit" \
      >/dev/null 2>&1 && [[ -s "$PREV_MANIFEST" ]]; then
    log "Fetched remote manifest ($(wc -l < "$PREV_MANIFEST" | tr -d ' ') files)."
  else
    log "No remote manifest — first deploy, all files will be uploaded."
  fi
fi

diff_changed "$LOCAL_MANIFEST" "$PREV_MANIFEST" "$CHANGED_LIST"

changed_count="$(wc -l < "$CHANGED_LIST" | tr -d ' ')"
if [[ "$changed_count" == "0" ]]; then
  ok "No new or edited files — server already up to date. Nothing to upload."
  exit 0
fi

log "Uploading $changed_count new/edited file(s) to $FTP_HOST:$REMOTE_BASE:"
sed 's/^/  ↑ /' "$CHANGED_LIST"

# Stage only the changed files into a delta tree, then add the manifest.
mkdir -p "$DELTA_DIR"
( cd "$OUT_DIR" && rsync -a --files-from="$CHANGED_LIST" ./ "$DELTA_DIR/" )
cp "$LOCAL_MANIFEST" "$DELTA_DIR/$REMOTE_MANIFEST_NAME"

# Upload the delta. lftp mirror -R may create sub-folders INSIDE $REMOTE_BASE
# (e.g. assets/…) but never the base folder itself — we are already inside it.
# cmd:fail-exit is REQUIRED: without it lftp exits 0 even when mirror -R
# failed partway (observed on GoDaddy: files silently skipped), which would
# make the script record a false "deployed" manifest.
if ! lftp -u "$FTP_USER","$FTP_PASS" "$FTP_HOST" -p "$FTP_PORT" <<EOF
set ftp:passive-mode on
set ssl:verify-certificate no
set cmd:fail-exit on
set net:max-retries 5
set net:timeout 30
set net:reconnect-interval-base 5
set net:reconnect-interval-max 60
cd $REMOTE_BASE
mirror -R --verbose "$DELTA_DIR" .
quit
EOF
then
  fail "FTP upload FAILED. The checksum manifest was NOT updated (unchanged files were not re-sent); failures retry next run."
fi

# Post-upload verification: dry-run the same delta again. If anything would
# still transfer, the upload was incomplete — abort WITHOUT updating the
# checksum manifest so the next run retries the missing files.
log "Verifying upload completeness (dry-run re-compare)..."
VERIFICATION_OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR" "$VERIFICATION_OUT"' EXIT
if ! lftp -u "$FTP_USER","$FTP_PASS" "$FTP_HOST" -p "$FTP_PORT" <<EOF | tee "$VERIFICATION_OUT"
set ftp:passive-mode on
set ssl:verify-certificate no
set cmd:fail-exit on
set net:max-retries 3
cd $REMOTE_BASE
mirror -R --dry-run --verbose "$DELTA_DIR" .
quit
EOF
then
  fail "Upload verification session failed. Manifest NOT updated; missing files will retry next run."
fi
if grep -qE '^(New: [1-9][0-9]* files|Transferring file)' "$VERIFICATION_OUT"; then
  echo "Files still missing after upload:" >&2
  grep -E '^Transferring file' "$VERIFICATION_OUT" | head -20 >&2
  grep -E '^New:' "$VERIFICATION_OUT" >&2
  fail "Upload incomplete (see list above). Manifest NOT updated — re-run this script to retry the missing files."
fi
ok "Upload verified complete on the server."

# Only record the deployment once every file uploaded.
cp "$LOCAL_MANIFEST" "$CACHE_MANIFEST"
ok "Uploaded $changed_count file(s). Checksum manifest updated ($CACHE_MANIFEST)."

# ------------------------------------------------- post-deploy smoke test ----
SITE_URL="${SITE_URL:-https://mesonxai.mesonsoft.com/}"
log "Post-deploy smoke test: $SITE_URL"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 15 "$SITE_URL" || true)"
case "$CODE" in
  200) ok "Live site returned HTTP 200." ;;
  000) warn "Live site did not respond — verify manually." ;;
  *)   warn "Live site returned HTTP $CODE (hosting may be caching — verify manually)." ;;
esac

ok "Deployment complete."

