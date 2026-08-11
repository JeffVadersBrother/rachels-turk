#!/usr/bin/env bash
#
# First-time setup for a fresh Raspberry Pi. Run this once; after that
# tools/deploy.sh does everything.
#
#   tools/provision.sh              set the Pi up
#   tools/provision.sh --dry-run    print what it would do, touch nothing
#
# It installs Node if the Pi has none (or too old a one), creates the install
# and data directories, installs the systemd unit, and enables the service. It
# does not copy any application code — deploy.sh's job — so it is safe to rerun.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SETTINGS="PI_HOST PI_DIR PI_SERVICE PI_PORT PI_DATA PI_USER"
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
PI_DATA="${PI_DATA:-/home/trevor/rachels-turk-data}"
# The user half of trevor@host. An ssh alias has no @ in it, and guessing the
# alias name as the username would write a unit systemd refuses to start — so
# ask the Pi who we actually logged in as.
if [ -z "${PI_USER:-}" ]; then
  case "$PI_HOST" in
    *@*) PI_USER="${PI_HOST%@*}" ;;
    *)   PI_USER="" ;;            # resolved over ssh below, once we know it works
  esac
fi
NODE_MAJOR=20

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -h|--help) awk 'NR>1{ if(/^#/){sub(/^# ?/,""); print} else exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1  (try --help)" >&2; exit 2 ;;
  esac
  shift
done

CTL_PATH='/tmp/.turk-prov-%r@%h-%p'
SSH_MUX="-o ControlMaster=auto -o ControlPath=$CTL_PATH -o ControlPersist=120"
ssh() { command ssh $SSH_MUX "$@"; }
scp() { command scp $SSH_MUX "$@"; }
trap 'command ssh -O exit -o ControlPath="$CTL_PATH" "$PI_HOST" 2>/dev/null; true' EXIT

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '   would run: %s\n' "$*"; else "$@"; fi; }

say "Pi — $PI_HOST"
[ "$DRY" = 0 ] && { ssh -o ConnectTimeout=10 "$PI_HOST" true 2>/dev/null \
  || die "cannot reach $PI_HOST over ssh"; }

if [ -z "$PI_USER" ]; then
  if [ "$DRY" = 1 ]; then
    PI_USER='<whoever ssh logs in as>'
  else
    PI_USER=$(ssh "$PI_HOST" 'id -un') || die "could not work out the login user on $PI_HOST"
  fi
fi
echo "   service will run as $PI_USER"

# ---- node -------------------------------------------------------------------

say "Checking Node"
if [ "$DRY" = 1 ]; then
  printf '   would install Node %s if the Pi has an older one or none\n' "$NODE_MAJOR"
else
  have=$(ssh "$PI_HOST" "node --version 2>/dev/null || true")
  major=$(printf '%s' "$have" | sed -n 's/^v\([0-9]*\).*/\1/p')
  if [ -n "$major" ] && [ "$major" -ge 18 ]; then
    echo "   $have — fine"
  else
    warn "  Node is ${have:-missing} — installing $NODE_MAJOR.x from NodeSource"
    ssh -t "$PI_HOST" "curl -fsSL https://deb.nodesource.com/setup_$NODE_MAJOR.x | sudo -E bash - && \
      sudo apt-get install -y nodejs"
    echo "   now $(ssh "$PI_HOST" 'node --version')"
  fi
fi

# ---- directories ------------------------------------------------------------

say "Creating directories"
run ssh "$PI_HOST" "mkdir -p '$PI_DIR' '$PI_DATA'"
echo "   install: $PI_DIR"
echo "   data:    $PI_DATA   (survives deploys and rollbacks)"

# ---- the service ------------------------------------------------------------
# The unit is templated here rather than shipped verbatim so the paths, port and
# user follow deploy.conf instead of being edited on the Pi where the next
# person will never find them.

say "Installing the $PI_SERVICE service"
UNIT=$(mktemp)
sed -e "s|@USER@|$PI_USER|g" \
    -e "s|@DIR@|$PI_DIR|g" \
    -e "s|@DATA@|$PI_DATA|g" \
    -e "s|@PORT@|$PI_PORT|g" \
    deploy/rachels-turk.service > "$UNIT"

if [ "$DRY" = 1 ]; then
  echo "   would install this unit as /etc/systemd/system/$PI_SERVICE.service:"
  sed 's/^/     /' "$UNIT"
  rm -f "$UNIT"
else
  scp -q "$UNIT" "$PI_HOST:/tmp/$PI_SERVICE.service"
  rm -f "$UNIT"
  ssh -t "$PI_HOST" "sudo install -m 644 /tmp/$PI_SERVICE.service /etc/systemd/system/$PI_SERVICE.service && \
    rm -f /tmp/$PI_SERVICE.service && \
    sudo systemctl daemon-reload && \
    sudo systemctl enable $PI_SERVICE"
  echo "   installed and enabled (starts on boot)"
fi

say "Done"
if [ "$DRY" = 1 ]; then
  echo "(dry run: nothing was changed)"
else
  cat <<EOF

The Pi is ready but has no code on it yet. Next:

  tools/deploy.sh

After that, http://${PI_HOST#*@}:$PI_PORT/api/health should answer.
EOF
fi
