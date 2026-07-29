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
  IMAGE_CACHE_DIR    upstream image cache            (default /var/cache/pickle-image-builder)
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

# A bare name. Anything with a slash or a leading dot reaches outside profiles/,
# and the loader sources what it is given as root while the manifest path is
# built from the same string.
case "$PROFILE" in
  ''|.*|*[!A-Za-z0-9._-]*) die "profile must be a bare name: $PROFILE" ;;
esac
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
[ "${#dump[@]}" -eq "$declared" ] || die "profile $PROFILE did not load cleanly (a syntax error, or a value containing a newline)"

declare -A PV=()
for line in "${dump[@]}"; do
  PV["${line%%=*}"]="${line#*=}"
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
SUDO_GROUP="${PV[SUDO_GROUP]}"
CPU_TYPE="${PV[CPU_TYPE]}"
SSHD_DROPIN_REMOVE="${PV[SSHD_DROPIN_REMOVE]:-}"
CHECKSUM_FORMAT="${PV[CHECKSUM_FORMAT]:-gnu}"
TEMPLATE_NAME="${TEMPLATE_NAME:-${PV[TEMPLATE_NAME]}}"

# virt-customize takes one comma-separated list. A profile written with spaces
# would otherwise become a single package name that no distribution has.
GUEST_PACKAGES=$(printf '%s' "${PV[GUEST_PACKAGES]}" | tr -s '[:space:],' ',' | sed 's/^,//; s/,$//')
[ -n "$GUEST_PACKAGES" ] || die "profile $PROFILE has an empty GUEST_PACKAGES"

# Every value that reaches a generated file. The manifest is JSON, where a quote
# or a backslash produces a file that parses as nothing and a control character
# is illegal outright; the rest land in guest configuration. TEMPLATE_NAME is
# checked here rather than with the profile because it may come from the
# environment, which the profile loader never sees.
for var in OS_FAMILY OS_VERSION TEMPLATE_NAME IMAGE_URL CHECKSUM_URL CHECKSUM_ALGO \
           CIUSER SUDO_GROUP CPU_TYPE GUEST_PACKAGES SSHD_DROPIN_REMOVE; do
  case "${!var}" in
    *'"'*|*\\*) die "$var contains a quote or backslash: ${!var}" ;;
    *[!\ -~]*) die "$var contains a control or non-ASCII character" ;;
  esac
done

STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr2}"
# Not Proxmox's ISO content directory: multi-gigabyte images and the transient
# work copies would show up in the ISO picker and count against that storage.
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/var/cache/pickle-image-builder}"
IMAGE_FILE="${IMAGE_URL##*/}"
[ -n "$IMAGE_FILE" ] || die "IMAGE_URL does not end in a file name: $IMAGE_URL"
IMAGE_PATH="${IMAGE_CACHE_DIR}/${IMAGE_FILE}"
# The algorithm names a command, so it stays a bare word: anything else would let
# a profile field decide which binary hashes the image.
case "$CHECKSUM_ALGO" in
  *[!a-z0-9]*|'') die "CHECKSUM_ALGO must be a bare name such as sha256: $CHECKSUM_ALGO" ;;
esac
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
  elif [ "$REBUILD" -eq 0 ]; then
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
SSHD_CONF=""
SUDOERS_CONF=""
GRUB_CONF=""
CLOUDCFG_CONF=""
cleanup() {
  rm -f "$WORK_IMG" \
    ${DOWNLOAD_TMP:+"$DOWNLOAD_TMP"} \
    ${SSHD_CONF:+"$SSHD_CONF"} \
    ${SUDOERS_CONF:+"$SUDOERS_CONF"} \
    ${GRUB_CONF:+"$GRUB_CONF"} \
    ${CLOUDCFG_CONF:+"$CLOUDCFG_CONF"}
}
trap cleanup EXIT

# The upstream checksum is compared against the cached image on every build, not
# only when downloading it. A cache checked for existence alone outlives the
# image it was verified against: the release channel republishes and every later
# rebuild bakes the stale copy while reporting success.
case "$CHECKSUM_FORMAT" in
  gnu)
    # "<hash>  <name>", the coreutils form; the star marks a binary read.
    expected=$(curl -fsSL "$CHECKSUM_URL" \
      | awk -v f="$IMAGE_FILE" 'NF >= 2 && ($2 == f || $2 == "*" f) {print $1}') ;;
  bsd)
    # "<ALGO> (<name>) = <hash>", which the Red Hat family publishes.
    expected=$(curl -fsSL "$CHECKSUM_URL" \
      | awk -v f="$IMAGE_FILE" 'NF == 4 && $2 == "(" f ")" && $3 == "=" {print $4}') ;;
  *) die "CHECKSUM_FORMAT must be gnu or bsd: $CHECKSUM_FORMAT" ;;
esac
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

# sshd drop-in. It sorts first on purpose: sshd keeps the FIRST value it obtains
# for a keyword, and distributions ship their own drop-ins at 50 and 60, so a
# higher number loses to them.
#
# Password authentication stays on. The platform forwards the password a user
# typed to the guest rather than substituting a key, because a user may change
# it in the guest and the stored value is then no longer the truth. Which VMs
# accept a password is decided at the gateway, and reachability on the paths that
# skip the gateway belongs to the network rules, not to every guest image.
SSHD_CONF="$(mktemp)"
{
  cat <<'CONF'
# Managed by the image builder. Numbered 01 so distribution drop-ins cannot win.
PasswordAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
ClientAliveInterval 60
ClientAliveCountMax 5
X11Forwarding no
UseDNS no
CONF
} > "$SSHD_CONF"

# sudoers: cloud-init writes /etc/sudoers.d/90-cloud-init-users granting the
# default user NOPASSWD. Sudo must demand the password instead, because the VM
# password is the sudo credential. Sudo reads /etc/sudoers.d in C-locale lexical
# order and the LAST matching rule wins, the opposite of sshd, so the name sorts
# to the end where no later cloud-init drop-in can tie with it.
#
# The rule names the group rather than the account. A rule naming an account the
# guest does not have matches nobody, which would leave cloud-init's passwordless
# rule as the last match and hand every VM from that template a sudo that never
# asks: the failure is silent, and visudo does not check that a named user
# exists. The group is what cloud-init puts the default user in.
#
# visudo -cf validates the file here, since a syntax error would otherwise
# surface only as a broken sudo on every VM. 0440 is the mode sudo requires.
SUDOERS_CONF="$(mktemp)"
cat > "$SUDOERS_CONF" <<SUDO
%${SUDO_GROUP} ALL=(ALL:ALL) PASSWD:ALL
Defaults passwd_tries=3
Defaults timestamp_timeout=5
SUDO

customize=(
  --install "$GUEST_PACKAGES"
  --timezone Asia/Seoul
)
if [ -n "$SSHD_DROPIN_REMOVE" ]; then
  # Quoted for the guest shell: the value reaches a command line inside the image.
  customize+=(--run-command "rm -f $(printf '%q' "$SSHD_DROPIN_REMOVE")")
fi
# GRUB. The cloud image hides the menu entirely (timeout 0), and Proxmox runs
# these guests with no VGA device, so a VM whose sshd does not come up has no way
# in at all: the web terminal is an SSH client too. A short menu on the serial
# console is the only path left for a guest that broke its own fstab or sudoers,
# and it costs three seconds per boot. The kernel already logs to both consoles;
# what is missing is GRUB itself talking to the serial line rather than to a
# screen that does not exist.
GRUB_CONF="$(mktemp)"
cat > "$GRUB_CONF" <<'GRUB'
# Managed by the image builder. Sorted after the cloud image's own settings.
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu
GRUB_RECORDFAIL_TIMEOUT=3
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB

# cloud-init probes every datasource it knows on each boot. Proxmox presents the
# seed as NoCloud; ConfigDrive stays for the other cloud-init type Proxmox can be
# told to use, and None keeps a missing seed from turning into a wait.
CLOUDCFG_CONF="$(mktemp)"
cat > "$CLOUDCFG_CONF" <<'CLOUDCFG'
# Managed by the image builder.
datasource_list: [ NoCloud, ConfigDrive, None ]
CLOUDCFG

customize+=(
  --mkdir /etc/ssh/sshd_config.d
  --upload "${SSHD_CONF}:/etc/ssh/sshd_config.d/01-pickle.conf"
  --run-command "chmod 644 /etc/ssh/sshd_config.d/01-pickle.conf"
  --upload "${SUDOERS_CONF}:/etc/sudoers.d/zz-pickle"
  --run-command "chmod 440 /etc/sudoers.d/zz-pickle && visudo -cf /etc/sudoers.d/zz-pickle"
  --upload "${GRUB_CONF}:/etc/default/grub.d/99-pickle.cfg"
  --upload "${CLOUDCFG_CONF}:/etc/cloud/cloud.cfg.d/99-pickle-datasource.cfg"
  --run-command "update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg"
  # Machine identity. Clones must not share one: systemd derives the journal id
  # and the default DHCP client id from it, and a duplicate makes two VMs look
  # like one wherever those are used. The systemd contract for an image is the
  # literal word rather than an empty file, and the D-Bus copy is a separate
  # file on these distributions rather than a link to the first.
  --run-command "printf 'uninitialized\\n' > /etc/machine-id &&
                 rm -f /var/lib/dbus/machine-id &&
                 rm -rf /var/lib/cloud/instance /var/lib/cloud/instances /var/lib/cloud/data"
)
virt-customize -a "$WORK_IMG" "${customize[@]}"

# A separate pass so that the host-key removal is the last thing to touch the
# image, whatever order the options above were folded in.
#
# What is checked here is the EFFECTIVE configuration, not the file. A syntax
# check passes whether or not the drop-in was read at all: a distribution whose
# sshd_config carries no Include line, or carries it after its own settings,
# produces a valid configuration in which none of these values apply. Asking
# sshd what it resolved catches that, and MaxAuthTries is the value to ask about
# because nothing but this file sets it.
#
# A template must carry no host keys. Every clone would share them, and because
# the platform pins the key it collects from each VM, a shared key would look
# healthy while protecting nothing between the gateway and the guests. Cloud
# images ship without them and cloud-init generates them on first boot; what this
# guards against is a package installed above putting them back. sshd will not
# resolve a configuration without a host key, so the same pass makes a throwaway
# set, asks its questions, and then leaves the image with none.
# shellcheck disable=SC2016  # the command runs in the guest, not here
virt-customize -a "$WORK_IMG" --run-command \
  'mkdir -p /run/sshd && ssh-keygen -A >/dev/null &&
   sshd -T | grep -qx "maxauthtries 3" &&
   sshd -T | grep -qx "passwordauthentication yes" &&
   rm -f /etc/ssh/ssh_host_* &&
   test -z "$(find /etc/ssh -maxdepth 1 -name "ssh_host_*" -print -quit)"'

# -------------------------------------------------------------------- build --
# From here on a failure can leave a half-built VMID, which the guard above
# turns into a loud error on the next run rather than a silent success.
if [ "$REBUILD" -eq 1 ] && qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  # The check above ran before a download, an image copy and two customization
  # passes: minutes in which a guest could appear at this id, and --purge does
  # not come back. What may be destroyed is a template, or the wreck of a run
  # that got as far as naming the VM but not as far as templating it. Anything
  # else is somebody's guest.
  if ! qm config "$TEMPLATE_VMID" | grep -q '^template: 1' &&
     ! qm config "$TEMPLATE_VMID" | grep -qxF "name: $TEMPLATE_NAME"; then
    die "VMID $TEMPLATE_VMID holds a guest that is neither a template nor a leftover of this build; inspect it before rebuilding"
  fi
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

# Proxmox tells cloud-init to run a full package upgrade on first boot. Measured
# on this image it was 19.5s of a 36s boot, and for that whole stretch the guest
# agent does not answer, which is exactly when the platform is polling it to
# collect the guest's host keys. The upgrade is also the largest memory spike a
# 1 GiB guest sees. Unattended upgrades are enabled inside the image, so the
# fixes still land; they land on the guest's own schedule instead of across
# provisioning.
qm set "$TEMPLATE_VMID" --ciupgrade 0
qm set "$TEMPLATE_VMID" --scsi0 "${STORAGE}:0,import-from=${WORK_IMG},discard=on"
qm set "$TEMPLATE_VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$TEMPLATE_VMID" --boot order=scsi0
qm template "$TEMPLATE_VMID"

# ---------------------------------------------------------------- provenance --
# A template is a build artifact with no record of its own inputs: the id and the
# name say nothing about which upstream image went in or which revision of this
# recipe shaped it. The manifest is written next to the recipe and committed, so
# a template that has been running for a year can still be traced to the bytes it
# came from. One file per template id: a rebuild replaces the record for that id,
# which is what "what is on that id now" should mean.
mkdir -p "$REPO_ROOT/manifests"
manifest="$REPO_ROOT/manifests/${PROFILE}-${TEMPLATE_VMID}.json"
recipe_revision=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
if ! git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null; then
  recipe_revision="${recipe_revision}-modified"
fi
cat > "$manifest" <<JSON
{
  "profile": "${PROFILE}",
  "osFamily": "${OS_FAMILY}",
  "osVersion": "${OS_VERSION}",
  "templateVmid": ${TEMPLATE_VMID},
  "templateName": "${TEMPLATE_NAME}",
  "imageUrl": "${IMAGE_URL}",
  "imageChecksum": "${expected}",
  "checksumUrl": "${CHECKSUM_URL}",
  "checksumAlgorithm": "${CHECKSUM_ALGO}",
  "cpuType": "${CPU_TYPE}",
  "ciUser": "${CIUSER}",
  "sudoGroup": "${SUDO_GROUP}",
  "guestPackages": "${GUEST_PACKAGES}",
  "recipeRevision": "${recipe_revision}",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
echo "wrote manifests/${PROFILE}-${TEMPLATE_VMID}.json"

echo "template $TEMPLATE_VMID (${TEMPLATE_NAME}, ${OS_FAMILY} ${OS_VERSION}) ready"
