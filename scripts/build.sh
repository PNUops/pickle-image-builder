#!/usr/bin/env bash
# Builds a cloud-init VM template on a Proxmox node from an OS profile.
# Idempotent: refuses to overwrite an existing template unless --rebuild is given.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

die() { echo "$*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage: scripts/build.sh <profile> <vmid> [--rebuild]

  profile   name under profiles/ without the extension (e.g. ubuntu-24.04)
  vmid      Proxmox id for the template, in the 1000-9999 template band

environment overrides:
  STORAGE            Proxmox storage for the disk    (default local-lvm)
  BRIDGE             bridge for net0                 (default vmbr2)
  IMAGE_CACHE_DIR    upstream image cache            (default /var/lib/vz/template/iso)
  TEMPLATE_NAME      overrides the profile's name

available profiles: $(for p in "$REPO_ROOT"/profiles/*.sh; do [ -e "$p" ] && basename "$p" .sh; done | paste -sd' ' -)
EOF
  exit 2
}

# ---------------------------------------------------------------- arguments --
# Parsed strictly. A mistyped flag must not read as "nothing to do, exit 0": an
# operator rebuilding to pick up a security-fixed image would see success, and
# the runbook's post-rebuild checks all pass against the template that is still
# there.
[ $# -ge 2 ] || usage
PROFILE="$1"
TEMPLATE_VMID="$2"
shift 2
REBUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) REBUILD=1 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done

PROFILE_PATH="$REPO_ROOT/profiles/${PROFILE}.sh"
[ -f "$PROFILE_PATH" ] || { echo "no such profile: $PROFILE" >&2; usage; }

case "$TEMPLATE_VMID" in
  ''|*[!0-9]*) die "vmid must be a number: $TEMPLATE_VMID" ;;
esac
# Base 10 explicitly: 01000 would otherwise reach qm as a different string than
# the operator typed, and the rebuild runbook asks them to match it against the
# guest list.
TEMPLATE_VMID=$((10#$TEMPLATE_VMID))
if [ "$TEMPLATE_VMID" -lt 1000 ] || [ "$TEMPLATE_VMID" -gt 9999 ]; then
  die "vmid $TEMPLATE_VMID is outside the template band 1000-9999"
fi
readonly PROFILE PROFILE_PATH TEMPLATE_VMID REBUILD REPO_ROOT

# ------------------------------------------------------------------ profile --
# A profile is read, never sourced here. It is shell, so sourcing it would let a
# stray assignment reach this script's own variables: the vmid band check and
# the rebuild flag both live in ordinary variables, and a profile carrying a
# leftover TEMPLATE_VMID would redirect the destroy below to whatever it names.
# The subshell starts from an empty environment so that a value missing from the
# profile is reported as missing instead of silently inherited from the caller.
profile_dump() {
  # shellcheck disable=SC2016  # the body runs in the child, not here
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin bash --noprofile --norc -c '
    set -euo pipefail
    . "$1"
    . "$2"
    for v in $PROFILE_REQUIRED_VARS $PROFILE_OPTIONAL_VARS; do
      printf "%s=%s\n" "$v" "${!v-}"
    done
  ' _ "$PROFILE_PATH" "$REPO_ROOT/scripts/profile-vars.sh"
}

# shellcheck source=scripts/profile-vars.sh
. "$REPO_ROOT/scripts/profile-vars.sh"

# The variable list is loaded after the profile inside the subshell too, so a
# profile cannot shrink it to hide a field it failed to set.
mapfile -t dump < <(profile_dump)
# One line per declared field. A value carrying a newline would otherwise be
# truncated at it and the remainder read as another field's assignment.
declared=$(printf '%s %s' "$PROFILE_REQUIRED_VARS" "$PROFILE_OPTIONAL_VARS" | wc -w)
[ "${#dump[@]}" -eq "$declared" ] || die "profile $PROFILE did not load cleanly (a value containing a newline?)"

declare -A PV=()
for line in "${dump[@]}"; do
  key="${line%%=*}"
  case " $PROFILE_REQUIRED_VARS $PROFILE_OPTIONAL_VARS " in
    *" $key "*) PV["$key"]="${line#*=}" ;;
    *) die "profile $PROFILE produced an unexpected field: $key" ;;
  esac
done

for var in $PROFILE_REQUIRED_VARS; do
  [ -n "${PV[$var]:-}" ] || die "profile $PROFILE does not set $var"
done

OS_FAMILY="${PV[OS_FAMILY]}"
OS_VERSION="${PV[OS_VERSION]}"
IMAGE_URL="${PV[IMAGE_URL]}"
CHECKSUM_URL="${PV[CHECKSUM_URL]}"
CHECKSUM_ALGO="${PV[CHECKSUM_ALGO]}"
CIUSER="${PV[CIUSER]}"
CPU_TYPE="${PV[CPU_TYPE]}"
SSHD_DROPIN_REMOVE="${PV[SSHD_DROPIN_REMOVE]:-}"
TEMPLATE_NAME="${TEMPLATE_NAME:-${PV[TEMPLATE_NAME]}}"

# virt-customize takes one comma-separated list. A profile written with spaces
# would otherwise become a single package name that no distribution has.
GUEST_PACKAGES=$(printf '%s' "${PV[GUEST_PACKAGES]}" | tr -s '[:space:],' ',' | sed 's/^,//; s/,$//')
[ -n "$GUEST_PACKAGES" ] || die "profile $PROFILE has an empty GUEST_PACKAGES"

STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr2}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/var/lib/vz/template/iso}"
IMAGE_FILE="${IMAGE_URL##*/}"
[ -n "$IMAGE_FILE" ] || die "IMAGE_URL does not end in a file name: $IMAGE_URL"
IMAGE_PATH="${IMAGE_CACHE_DIR}/${IMAGE_FILE}"
SUM_CMD="${CHECKSUM_ALGO}sum"

command -v qm >/dev/null || die "qm not found; run this on a Proxmox node"
command -v "$SUM_CMD" >/dev/null || die "no such checksum tool: $SUM_CMD (CHECKSUM_ALGO=$CHECKSUM_ALGO)"

# One build at a time. Two builds of the same profile share the download path,
# and a rebuild that destroys while another run is mid-import leaves both
# without a template.
# A fixed path: taking it from the environment would give two operators with
# different settings two locks and no serialisation at all.
LOCK_DIR=/var/lock
[ -d "$LOCK_DIR" ] || LOCK_DIR=/tmp
exec 9>"$LOCK_DIR/pickle-image-builder.lock"
flock -n 9 || die "another build is running"

# ------------------------------------------------------------ existing vmid --
# Existence is not the question; being a usable template is. A run that failed
# between qm create and qm template leaves a diskless VM at this id, and
# answering "already exists, nothing to do" with status 0 would let automation
# clone it into VMs with no disk and no cloud-init drive.
if qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  if qm config "$TEMPLATE_VMID" | grep -q '^template: 1'; then
    [ "$REBUILD" -eq 1 ] || {
      echo "VMID $TEMPLATE_VMID is already a template; use --rebuild to replace. Nothing to do."
      exit 0
    }
  else
    die "VMID $TEMPLATE_VMID exists but is not a template (leftover from a failed build?); inspect it, then re-run with --rebuild"
  fi
fi

command -v virt-customize >/dev/null || {
  echo "installing libguestfs-tools (for virt-customize)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libguestfs-tools
}

# --------------------------------------------------------------- base image --
# Everything that can fail happens before the existing template is destroyed, so
# a failed rebuild leaves the node with the template it had. Fetching the
# checksum needs egress, which the previous recipe did not on a warm cache.
mkdir -p "$IMAGE_CACHE_DIR"
WORK_IMG="${IMAGE_CACHE_DIR}/pickle-${TEMPLATE_VMID}-${IMAGE_FILE}"
DOWNLOAD_TMP=""
cleanup() { rm -f "$WORK_IMG" ${DOWNLOAD_TMP:+"$DOWNLOAD_TMP"}; }
trap cleanup EXIT

# The upstream checksum is compared against the cached image on every build, not
# only when downloading it. A cache checked for existence alone outlives the
# image it was verified against: the release channel republishes and every later
# rebuild bakes the stale copy while reporting success.
expected=$(curl -fsSL "$CHECKSUM_URL" \
  | awk -v f="$IMAGE_FILE" 'NF >= 2 && ($2 == f || $2 == "*" f) {print $1}')
[ -n "$expected" ] || die "no $CHECKSUM_ALGO entry for $IMAGE_FILE in $CHECKSUM_URL"
[ "$(printf '%s\n' "$expected" | wc -l)" -eq 1 ] || die "$IMAGE_FILE is listed more than once in $CHECKSUM_URL"
case "$expected" in
  *[!0-9a-fA-F]*|'') die "checksum for $IMAGE_FILE is not a hash: $expected" ;;
esac

cached=""
if [ -f "$IMAGE_PATH" ]; then
  cached=$("$SUM_CMD" "$IMAGE_PATH" | awk '{print $1}')
fi
if [ "$cached" = "$expected" ]; then
  echo "using cached $IMAGE_FILE"
else
  echo "downloading $IMAGE_FILE"
  DOWNLOAD_TMP=$(mktemp "${IMAGE_PATH}.XXXXXX")
  curl -fL --retry 3 -o "$DOWNLOAD_TMP" "$IMAGE_URL"
  actual=$("$SUM_CMD" "$DOWNLOAD_TMP" | awk '{print $1}')
  [ "$expected" = "$actual" ] || die "$CHECKSUM_ALGO mismatch: expected $expected got $actual"
  mv "$DOWNLOAD_TMP" "$IMAGE_PATH"
  DOWNLOAD_TMP=""
fi

# ---------------------------------------------------------------- customize --
# The verified upstream image stays in the cache; customization happens on a
# copy named for this build so two runs cannot collide.
cp -f "$IMAGE_PATH" "$WORK_IMG"

# sudoers: cloud-init writes /etc/sudoers.d/90-cloud-init-users granting the
# default user NOPASSWD. Sudo must demand the password instead, because the VM
# password is the sudo credential. Sudo reads /etc/sudoers.d in C-locale lexical
# order and the LAST matching rule wins, so 99-pickle sorts after
# 90-cloud-init-users and overrides it. visudo -cf validates the drop-in here; a
# syntax error would otherwise surface only as a broken sudo on every VM built
# from the template. 0440 is the mode sudo requires.
customize=(
  --install "$GUEST_PACKAGES"
  --timezone Asia/Seoul
)
if [ -n "$SSHD_DROPIN_REMOVE" ]; then
  # Quoted for the guest shell: the value reaches a command line inside the image.
  customize+=(--run-command "rm -f $(printf '%q' "$SSHD_DROPIN_REMOVE")")
fi
customize+=(
  --write "/etc/ssh/sshd_config.d/55-pickle.conf:PasswordAuthentication yes"
  --write "/etc/sudoers.d/99-pickle:${CIUSER} ALL=(ALL:ALL) PASSWD:ALL"
  --run-command "chmod 440 /etc/sudoers.d/99-pickle && visudo -cf /etc/sudoers.d/99-pickle"
  --truncate /etc/machine-id
)
virt-customize -a "$WORK_IMG" "${customize[@]}"

# -------------------------------------------------------------------- build --
# From here on a failure can leave a half-built VMID, which the guard above
# turns into a loud error on the next run rather than a silent success.
if [ "$REBUILD" -eq 1 ] && qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  echo "removing existing VMID $TEMPLATE_VMID for rebuild"
  qm destroy "$TEMPLATE_VMID" --purge
fi

echo "creating VM $TEMPLATE_VMID"
qm create "$TEMPLATE_VMID" \
  --name "$TEMPLATE_NAME" \
  --ostype l26 \
  --cpu "$CPU_TYPE" \
  --cores 2 \
  --memory 2048 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-single \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

qm set "$TEMPLATE_VMID" --scsi0 "${STORAGE}:0,import-from=${WORK_IMG},discard=on"
qm set "$TEMPLATE_VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$TEMPLATE_VMID" --boot order=scsi0
qm template "$TEMPLATE_VMID"

echo "template $TEMPLATE_VMID (${TEMPLATE_NAME}, ${OS_FAMILY} ${OS_VERSION}) ready"
