#!/usr/bin/env bash
#
# Deploy rachels-turk to the Raspberry Pi from your laptop.
#
#   tools/deploy.sh                 run the tests, then deploy
#   tools/deploy.sh --dry-run       print what it would do, touch nothing
#   tools/deploy.sh --skip-tests    deploy without running the suite
#   tools/deploy.sh --rollback      put the Pi back on the previous release
#   tools/deploy.sh --logs          tail the service log and exit
#
# Settings come from tools/deploy.conf (gitignored — copy deploy.conf.example).
# Environment variables win over the file, so a one-off is just:
#
#   PI_HOST=trevor@192.168.1.50 tools/deploy.sh
#
# First time on a fresh Pi, run tools/provision.sh instead — it installs the
# systemd unit this script restarts.
#
# Written for the bash 3.2 that ships with macOS: no associative arrays.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# ---- settings ---------------------------------------------------------------

# Sourcing the file plainly would clobber anything already in the environment,
# which is backwards: a one-off `PI_HOST=... tools/deploy.sh` has to win over
# the committed-to defaults. Stash the environment, source, then put it back.
SETTINGS="PI_HOST PI_DIR PI_SERVICE PI_PORT PI_RELEASES KEEP_RELEASES"
for _k in $SETTINGS; do eval "_env_$_k=\"\${$_k:-}\""; done
[ -f tools/deploy.conf ] && . tools/deploy.conf
for _k in $SETTINGS; do
  eval "_v=\$_env_$_k"
  [ -n "$_v" ] && eval "$_k=\"\$_v\""
done

PI_HOST="${PI_HOST:-trevor@192.168.1.119}"
PI_DIR="${PI_DIR:-/home/trevor/rachels-turk}"
PI_SERVICE="${PI_SERVICE:-rachels-turk}"
PI_PORT="${PI_PORT:-3100}"
PI_RELEASES="${PI_RELEASES:-/home/trevor/rachels-turk-releases}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"

RUN_TESTS=1; DRY=0; ROLLBACK=0; ASSUME_YES=0; LOGS_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-tests)  RUN_TESTS=0 ;;
    --dry-run)     DRY=1 ;;
    --rollback)    ROLLBACK=1 ;;
    --logs)        LOGS_ONLY=1 ;;
    -y|--yes)      ASSUME_YES=1 ;;
    -h|--help)     awk 'NR>1{ if(/^#/){sub(/^# ?/,""); print} else exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1  (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# One authentication per host instead of one per command. A deploy runs a dozen
# separate ssh/scp calls, and without multiplexing every one of them prompts,
# which trains you to type the password without reading what asked for it.
#
# These shadow ssh and scp deliberately, so every call site below gets it
# without having to remember; `command` reaches the real binaries.
CTL_PATH='/tmp/.turk-%r@%h-%p'
SSH_MUX="-o ControlMaster=auto -o ControlPath=$CTL_PATH -o ControlPersist=120"
ssh() { command ssh $SSH_MUX "$@"; }
scp() { command scp $SSH_MUX "$@"; }

cleanup() {
  rm -rf "${STAGE:-}" "${PAYLOAD:-}" 2>/dev/null
  # Drop the shared connection rather than leaving it idling for two minutes.
  [ -n "${PI_HOST:-}" ] && command ssh -O exit -o ControlPath="$CTL_PATH" "$PI_HOST" 2>/dev/null
  return 0
}
trap cleanup EXIT

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '   would run: %s\n' "$*"; else "$@"; fi; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY" = 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r reply </dev/tty || reply=n
  case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# `ssh -t` so a sudo password prompt on the far end still works.
pi_sudo() { run ssh -t "$PI_HOST" "$@"; }

[ -z "$PI_HOST" ] && die "PI_HOST is not set — see tools/deploy.conf.example"

# ---- --logs -----------------------------------------------------------------

if [ "$LOGS_ONLY" = 1 ]; then
  exec command ssh $SSH_MUX -t "$PI_HOST" "journalctl -u $PI_SERVICE -n 100 -f"
fi

# ---- rollback ---------------------------------------------------------------

if [ "$ROLLBACK" = 1 ]; then
  say "Releases on the Pi"
  ssh "$PI_HOST" "ls -1t $PI_RELEASES/*.tar.gz 2>/dev/null | head -$KEEP_RELEASES" || die "no releases found"
  prev=$(ssh "$PI_HOST" "ls -1t $PI_RELEASES/*.tar.gz 2>/dev/null | head -1")
  [ -n "$prev" ] || die "nothing to roll back to"
  confirm "Restore $prev and restart $PI_SERVICE?" || { echo "aborted"; exit 0; }
  run ssh "$PI_HOST" "tar xzf '$prev' -C '$PI_DIR'"
  pi_sudo "sudo systemctl restart $PI_SERVICE"
  say "rolled back to $prev"
  exit 0
fi

# ---- preflight --------------------------------------------------------------

say "Preflight"

if [ -n "$(git status --porcelain)" ]; then
  warn "working tree has uncommitted changes — you will not be able to tell later"
  warn "exactly what is running on the Pi."
  confirm "Deploy anyway?" || { echo "aborted"; exit 0; }
fi

if [ -n "$(git log '@{upstream}..HEAD' --oneline 2>/dev/null || true)" ]; then
  warn "HEAD is ahead of origin — deploying code that is not pushed."
  confirm "Deploy anyway?" || { echo "aborted"; exit 0; }
fi

if [ "$RUN_TESTS" = 1 ]; then
  say "Running the test suite"
  npm test >/tmp/turk-deploy-test.log 2>&1 \
    || { tail -30 /tmp/turk-deploy-test.log; die "tests failed — nothing deployed"; }
  echo "   suite green"
else
  warn "skipping tests (--skip-tests)"
fi

SHA=$(git rev-parse --short HEAD)
DIRTY=""; [ -n "$(git status --porcelain)" ] && DIRTY="+dirty"
STAMP=$(date -u +%Y%m%d-%H%M%S)
echo "   deploying $SHA$DIRTY"

# ---- build the payload ------------------------------------------------------
# The service and its tools, nothing else. node_modules, data/ and test/ are
# deliberately absent, so extracting over the install leaves the runtime state
# and any native builds alone.

STAGE=$(mktemp -d)
PAYLOAD="$STAGE.tar.gz"                 # sibling, so it is not inside its own tar
say "Building payload"
mkdir -p "$STAGE/src" "$STAGE/tools" "$STAGE/deploy" "$STAGE/docs"
cp package.json README.md LICENSE "$STAGE/"
[ -f package-lock.json ] && cp package-lock.json "$STAGE/"
# -R so nested source directories come along as the engine grows.
cp -R src/. "$STAGE/src/"
cp tools/deploy.sh tools/provision.sh "$STAGE/tools/"
cp deploy/*.service "$STAGE/deploy/"
cp docs/*.md "$STAGE/docs/" 2>/dev/null || true
printf '%s\n' "commit=$SHA$DIRTY" "deployed=$STAMP" "by=$(whoami)@$(hostname -s)" \
  > "$STAGE/DEPLOYED"
find "$STAGE" -name '.DS_Store' -delete
# COPYFILE_DISABLE keeps AppleDouble ._ files out. --no-xattrs is the other
# half: without it macOS packs com.apple.provenance into every entry and GNU
# tar on the Pi prints "Ignoring unknown extended header keyword" once per
# file, which buries anything that actually matters.
#
# Built even on a dry run — it is local only, and it makes the dry run report a
# real size and file count rather than a guess.
COPYFILE_DISABLE=1 tar czf "$PAYLOAD" --no-xattrs -C "$STAGE" .
echo "   $(du -h "$PAYLOAD" | cut -f1) — $(tar tzf "$PAYLOAD" | grep -c .) entries"

# ---- the Pi -----------------------------------------------------------------

say "Pi — $PI_HOST"

[ "$DRY" = 0 ] && { ssh -o ConnectTimeout=10 "$PI_HOST" true 2>/dev/null \
  || die "cannot reach $PI_HOST over ssh"; }

# Refuse to deploy onto a Pi that has never been provisioned — otherwise the
# files land, the restart fails, and the error you get names systemd rather
# than the thing you actually skipped.
if [ "$DRY" = 0 ]; then
  ssh "$PI_HOST" "systemctl cat $PI_SERVICE >/dev/null 2>&1" \
    || die "$PI_SERVICE is not installed on the Pi — run tools/provision.sh first"
fi

# Keep the current release so --rollback has somewhere to go. node_modules and
# data are excluded: they are not ours to restore and would bloat every copy.
say "  backing up the current release"
run ssh "$PI_HOST" "mkdir -p '$PI_RELEASES' && \
  tar czf '$PI_RELEASES/$STAMP.tar.gz' -C '$PI_DIR' \
    --exclude=node_modules --exclude=data . 2>/dev/null || true"
run ssh "$PI_HOST" "ls -1t '$PI_RELEASES'/*.tar.gz 2>/dev/null | \
  tail -n +$((KEEP_RELEASES + 1)) | xargs -r rm -f"

say "  uploading"
run scp -q "$PAYLOAD" "$PI_HOST:/tmp/rachels-turk-deploy.tar.gz"

say "  extracting into $PI_DIR"
run ssh "$PI_HOST" "mkdir -p '$PI_DIR' && \
  tar xzf /tmp/rachels-turk-deploy.tar.gz -C '$PI_DIR' && \
  rm -f /tmp/rachels-turk-deploy.tar.gz"

# Only reinstall when the dependencies actually moved. Anything with native
# bindings takes minutes on a Pi; skipping it is most of why a deploy is quick.
if [ "$DRY" = 1 ]; then
  printf '   would compare dependencies and npm install only if they moved\n'
else
  local_deps=$(node -e 'process.stdout.write(JSON.stringify(require("./package.json").dependencies||{}))')
  remote_deps=$(ssh "$PI_HOST" "cat '$PI_DIR/package.json' 2>/dev/null" \
    | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        try{process.stdout.write(JSON.stringify(JSON.parse(d).dependencies||{}))}catch(e){process.stdout.write("?")}})' \
    2>/dev/null || echo '?')
  if [ "$local_deps" = "{}" ]; then
    echo "   no dependencies yet, skipping npm install"
  elif [ "$local_deps" != "$remote_deps" ]; then
    warn "  dependencies changed — running npm install (this is the slow one)"
    ssh "$PI_HOST" "cd '$PI_DIR' && npm install --omit=dev --no-audit --no-fund"
  else
    echo "   dependencies unchanged, skipping npm install"
  fi
fi

say "  restarting $PI_SERVICE"
pi_sudo "sudo systemctl restart $PI_SERVICE"

if [ "$DRY" = 0 ]; then
  sleep 3
  if ! ssh "$PI_HOST" "systemctl is-active --quiet $PI_SERVICE"; then
    warn "  service is not active — last 30 log lines:"
    ssh "$PI_HOST" "journalctl -u $PI_SERVICE -n 30 --no-pager" || true
    die "deploy failed on the Pi. tools/deploy.sh --rollback puts it back."
  fi
  health=$(ssh "$PI_HOST" "curl -sf --max-time 5 localhost:$PI_PORT/api/health || true")
  case "$health" in
    *'"ok":true'*) echo "   health ok" ;;
    "")            warn "  service is up but /api/health did not answer yet" ;;
    *)             warn "  unexpected health response: $(echo "$health" | head -c 120)" ;;
  esac
  running=$(ssh "$PI_HOST" "cat '$PI_DIR/DEPLOYED' 2>/dev/null | head -1" || true)
  echo "   now running: ${running:-unknown}"
fi

say "Done — $SHA$DIRTY"
[ "$DRY" = 1 ] && echo "(dry run: nothing was changed)"
exit 0
