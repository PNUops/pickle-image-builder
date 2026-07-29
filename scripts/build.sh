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
# shellcheck source=scripts/profile-vars.sh
. "$REPO_ROOT/scripts/profile-vars.sh"

mapfile -t dump < <(profile_load "$PROFILE_PATH")
# One line per declared field. Fewer means the profile stopped early or a value
# carried a newline, in which case the remainder would read as another field.
[ "${#dump[@]}" -eq "$(profile_declared_count)" ] ||
  die "profile $PROFILE did not load cleanly (a syntax error, an early exit, or a value containing a newline)"

profile_validate dump || die "profile $PROFILE is not usable (see above)"

declare -A PV=()
for line in "${dump[@]}"; do
  PV["${line%%=*}"]="${line#*=}"
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
TEMPLATE_NAME="${PV[TEMPLATE_NAME]}"

# virt-customize takes one comma-separated list. A profile written with spaces
# would otherwise become a single package name that no distribution has.
GUEST_PACKAGES=$(printf '%s' "${PV[GUEST_PACKAGES]}" | tr -s '[:space:],' ',' | sed 's/^,//; s/,$//')
[ -n "$GUEST_PACKAGES" ] || die "profile $PROFILE has an empty GUEST_PACKAGES"

STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr2}"
# Not Proxmox's ISO content directory: multi-gigabyte images and the transient
# work copies would show up in the ISO picker and count against that storage.
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/var/cache/pickle-image-builder}"
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
  if [ "$REBUILD" -eq 0 ]; then
    if qm config "$TEMPLATE_VMID" | grep -q '^template: 1'; then
      echo "VMID $TEMPLATE_VMID is already a template; use --rebuild to replace. Nothing to do."
      exit 0
    fi
    die "VMID $TEMPLATE_VMID exists but is not a template (leftover from a failed build?); inspect it, then re-run with --rebuild"
  fi
  # --rebuild replaces this profile's own template, or the wreck of a run that
  # named the guest but never templated it. A template built from another profile
  # carries another name, and mistyping one vmid for another is likelier than
  # anything the template flag distinguishes. Checked here so the collision is
  # reported before a download rather than after it.
  qm config "$TEMPLATE_VMID" | grep -qxF "name: $TEMPLATE_NAME" ||
    die "VMID $TEMPLATE_VMID holds a guest named something other than $TEMPLATE_NAME; inspect it before rebuilding"
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
LIMITS_CONF=""
JOURNALD_CONF=""
COREDUMP_CONF=""
APT_CONF=""
NEEDRESTART_CONF=""
MANIFEST_BODY=""
MOTD_SCRIPT=""
ISSUE_TEXT=""
APT_TIMER_CONF=""
cleanup() {
  rm -f "$WORK_IMG" \
    ${DOWNLOAD_TMP:+"$DOWNLOAD_TMP"} \
    ${SSHD_CONF:+"$SSHD_CONF"} \
    ${SUDOERS_CONF:+"$SUDOERS_CONF"} \
    ${GRUB_CONF:+"$GRUB_CONF"} \
    ${CLOUDCFG_CONF:+"$CLOUDCFG_CONF"} \
    ${LIMITS_CONF:+"$LIMITS_CONF"} \
    ${JOURNALD_CONF:+"$JOURNALD_CONF"} \
    ${COREDUMP_CONF:+"$COREDUMP_CONF"} \
    ${APT_CONF:+"$APT_CONF"} \
    ${NEEDRESTART_CONF:+"$NEEDRESTART_CONF"} \
    ${APT_TIMER_CONF:+"$APT_TIMER_CONF"} \
    ${MANIFEST_BODY:+"$MANIFEST_BODY"} \
    ${MOTD_SCRIPT:+"$MOTD_SCRIPT"} \
    ${ISSUE_TEXT:+"$ISSUE_TEXT"}
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
      | awk -v f="$IMAGE_FILE" -v a="$CHECKSUM_ALGO" \
          'NF == 4 && tolower($1) == tolower(a) && $2 == "(" f ")" && $3 == "=" {print $4}') ;;
  *) die "CHECKSUM_FORMAT must be gnu or bsd: $CHECKSUM_FORMAT" ;;
esac
[ -n "$expected" ] || die "no $CHECKSUM_ALGO entry for $IMAGE_FILE in $CHECKSUM_URL"
[ "$(printf '%s\n' "$expected" | wc -l)" -eq 1 ] || die "$IMAGE_FILE is listed more than once in $CHECKSUM_URL"
case "$expected" in
  *[!0-9a-fA-F]*|'') die "checksum for $IMAGE_FILE is not a hash: $expected" ;;
esac

expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
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
# The one value in the drop-in that no distribution default matches, which is
# what lets the build use it as evidence that the file was read at all.
SSHD_MAX_AUTH_TRIES=3

SSHD_CONF="$(mktemp)"
{
  cat <<CONF
# Managed by the image builder. Numbered 01 so distribution drop-ins cannot win.
PasswordAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries ${SSHD_MAX_AUTH_TRIES}
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
  # The timezone option moves the /etc/localtime link and leaves the text file
  # behind. systemd reads the link, so the clock looks right until something
  # reconfigures tzdata from the file and the guest quietly goes back to UTC.
  --run-command "[ -f /etc/timezone ] && printf 'Asia/Seoul\\n' > /etc/timezone; true"
  # Korean is the interface language. Which tool generates a locale differs by
  # family, so the image is asked what it has rather than told what it is; the
  # Red Hat family carries the locale in a package the profile installs.
  --run-command "if command -v locale-gen >/dev/null 2>&1; then sed -i 's/^# *\\(ko_KR.UTF-8 UTF-8\\)/\\1/' /etc/locale.gen; locale-gen >/dev/null; update-locale LANG=ko_KR.UTF-8; else printf 'LANG=ko_KR.UTF-8\\n' > /etc/locale.conf; fi; locale -a | grep -qi '^ko_KR' || { echo 'the ko_KR locale is not present in this image' >&2; exit 1; }"
  # git prints a paragraph about the default branch name on every init otherwise.
  --run-command "command -v git >/dev/null && git config --system init.defaultBranch main; true"
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

# Kernel and daemon limits the distribution leaves where a small guest cannot
# live with them. Each value here was measured on the image rather than copied
# from a hardening list: the inotify ceiling is derived from RAM and lands around
# fifteen thousand, which an editor's remote session or a watching build exhausts
# while reporting something that names neither; a panicked kernel sits dead
# because the reboot timer is off; and the journal and core dumps are each
# allowed a tenth of the filesystem, which on a ten gigabyte disk is the
# student's disk filling up quietly.
LIMITS_CONF="$(mktemp)"
cat > "$LIMITS_CONF" <<'LIMITS'
# Managed by the image builder.
fs.inotify.max_user_watches = 262144
fs.inotify.max_user_instances = 512
kernel.panic = 10
LIMITS

JOURNALD_CONF="$(mktemp)"
cat > "$JOURNALD_CONF" <<'JOURNALD'
# Managed by the image builder.
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
JOURNALD

# A template records nothing about its own inputs: the id and the name say
# nothing about which upstream image went in or which revision of this recipe
# shaped it, and the release channel the image came from moves. The same record
# goes into the repository and into the guest, so a VM still running a year later
# can answer the question without anyone correlating ids.
MANIFEST_BODY="$(mktemp)"
recipe_revision=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
if ! git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null; then
  recipe_revision="${recipe_revision}-modified"
fi
cat > "$MANIFEST_BODY" <<JSON
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

# What a student sees on the way in. The message of the day is the only channel
# that reaches every guest without the platform pushing anything, and it cannot
# be changed on a VM that already exists, so it says the few things somebody
# logging in for the first time needs and nothing that will go stale.
MOTD_SCRIPT="$(mktemp)"
cat > "$MOTD_SCRIPT" <<'MOTD'
#!/bin/sh
# Managed by the image builder. The distribution's own header already names the
# release, so this starts from what the platform has to say.
printf '\n  부산대학교 클라우드 플랫폼에서 만든 가상 머신입니다.\n\n'
printf '  sudo 는 이 VM 의 비밀번호를 묻습니다. 콘솔에서 확인할 수 있습니다.\n'
printf '  영어 메시지로 보려면 명령 앞에 LC_ALL=C 를 붙이세요.\n'
[ -f /var/run/reboot-required ] &&
  printf '  업데이트 적용을 위해 재부팅이 필요합니다.\n'
df -P / 2>/dev/null | awk 'NR==2 && int($5) > 90 {
  printf "  디스크가 %s 찼습니다. 정리가 필요합니다.\n", $5 }'
printf '\n'
MOTD

ISSUE_TEXT="$(mktemp)"
cat > "$ISSUE_TEXT" <<'ISSUE'
부산대학교 클라우드 플랫폼 가상 머신입니다.
접속 기록이 남으며, 하이퍼바이저 운영자는 이 VM 의 디스크와 콘솔에 접근할 수 있습니다.

ISSUE

APT_CONF="$(mktemp)"
cat > "$APT_CONF" <<'APTCONF'
// Managed by the image builder.
// A conffile prompt during an unattended run wedges dpkg, and every later apt
// command then fails until somebody runs dpkg --configure by hand.
Dpkg::Options { "--force-confdef"; "--force-confold"; };
APT::Keep-Downloaded-Packages "false";
APTCONF

NEEDRESTART_CONF="$(mktemp)"
cat > "$NEEDRESTART_CONF" <<'NRCONF'
# Managed by the image builder.
# Interactively this asks which services to restart, which is a full-screen
# prompt on every apt install a student runs. Non-interactively it only lists
# them, so an unattended upgrade restarts nothing and the fix does not take
# effect until the next reboot.
$nrconf{restart} = 'a';
$nrconf{kernelhints} = -1;
NRCONF

APT_TIMER_CONF="$(mktemp)"
cat > "$APT_TIMER_CONF" <<'TIMER'
# Managed by the image builder.
# A fresh guest has no record of a previous run, so the catch-up fires while the
# user is still logging in for the first time and takes the dpkg lock with it.
[Timer]
OnBootSec=30min
RandomizedDelaySec=60min
TIMER

COREDUMP_CONF="$(mktemp)"
cat > "$COREDUMP_CONF" <<'COREDUMP'
# Managed by the image builder. Dumps stay available for debugging, bounded so
# that one runaway process cannot take the disk with it.
[Coredump]
MaxUse=200M
ProcessSizeMax=256M
COREDUMP

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
  --mkdir /etc/systemd/journald.conf.d
  --mkdir /etc/systemd/coredump.conf.d
  --upload "${LIMITS_CONF}:/etc/sysctl.d/99-pickle.conf"
  --upload "${JOURNALD_CONF}:/etc/systemd/journald.conf.d/99-pickle.conf"
  --upload "${COREDUMP_CONF}:/etc/systemd/coredump.conf.d/99-pickle.conf"
  --upload "${APT_CONF}:/etc/apt/apt.conf.d/99-pickle"
  --mkdir /etc/pickle
  --upload "${MANIFEST_BODY}:/etc/pickle/image.json"
  --mkdir /etc/update-motd.d
  --upload "${MOTD_SCRIPT}:/etc/update-motd.d/00-pickle"
  --upload "${ISSUE_TEXT}:/etc/issue"
  --upload "${ISSUE_TEXT}:/etc/issue.net"
  # The distribution's own message of the day fetches news from the vendor on a
  # timer, advertises a support subscription, and recomputes a system summary on
  # every single login. None of that belongs on a student's VM.
  --run-command "if [ -d /etc/update-motd.d ]; then chmod -x /etc/update-motd.d/*motd-news* /etc/update-motd.d/*landscape* /etc/update-motd.d/*esm* /etc/update-motd.d/*contract* /etc/update-motd.d/*release-upgrade* 2>/dev/null; fi; true"
  --run-command "chmod 755 /etc/update-motd.d/00-pickle; chmod 644 /etc/issue /etc/issue.net /etc/pickle/image.json"
  --mkdir /etc/needrestart/conf.d
  --upload "${NEEDRESTART_CONF}:/etc/needrestart/conf.d/99-pickle.conf"
  --mkdir /etc/systemd/system/apt-daily.timer.d
  --mkdir /etc/systemd/system/apt-daily-upgrade.timer.d
  --upload "${APT_TIMER_CONF}:/etc/systemd/system/apt-daily.timer.d/99-pickle.conf"
  --upload "${APT_TIMER_CONF}:/etc/systemd/system/apt-daily-upgrade.timer.d/99-pickle.conf"
  # Upload keeps the mode of the local file and mktemp makes them private, while
  # everything written here is ordinary configuration any process may read.
  --run-command "chmod 644 /etc/sysctl.d/99-pickle.conf /etc/systemd/journald.conf.d/99-pickle.conf /etc/systemd/coredump.conf.d/99-pickle.conf /etc/apt/apt.conf.d/99-pickle /etc/needrestart/conf.d/99-pickle.conf /etc/systemd/system/apt-daily.timer.d/99-pickle.conf /etc/systemd/system/apt-daily-upgrade.timer.d/99-pickle.conf /etc/default/grub.d/99-pickle.cfg /etc/cloud/cloud.cfg.d/99-pickle-datasource.cfg"
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
virt-customize -a "$WORK_IMG" --run-command "
   mkdir -p /run/sshd && ssh-keygen -A >/dev/null
   getent group $(printf '%q' "$SUDO_GROUP") >/dev/null ||
     { echo 'sudo group $SUDO_GROUP does not exist in this image' >&2; exit 1; }
   sshd -T | grep -qx 'maxauthtries ${SSHD_MAX_AUTH_TRIES}' ||
     { echo 'the sshd drop-in did not take effect' >&2; exit 1; }
   rm -f /etc/ssh/ssh_host_*
   test -z \"\$(find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -print -quit)\" ||
     { echo 'host keys survived removal' >&2; exit 1; }"

# -------------------------------------------------------------------- build --
# From here on a failure can leave a half-built VMID, which the guard above
# turns into a loud error on the next run rather than a silent success.
if [ "$REBUILD" -eq 1 ] && qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
  # Asked again: the check above ran before a download, an image copy and two
  # customization passes, minutes in which a guest could appear at this id, and
  # --purge does not come back.
  qm config "$TEMPLATE_VMID" | grep -qxF "name: $TEMPLATE_NAME" ||
    die "VMID $TEMPLATE_VMID now holds a guest named something other than $TEMPLATE_NAME; inspect it before rebuilding"
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
mkdir -p "$REPO_ROOT/manifests"
manifest="$REPO_ROOT/manifests/${PROFILE}-${TEMPLATE_VMID}.json"
cp "$MANIFEST_BODY" "$manifest"
echo "wrote manifests/${PROFILE}-${TEMPLATE_VMID}.json"

echo "template $TEMPLATE_VMID (${TEMPLATE_NAME}, ${OS_FAMILY} ${OS_VERSION}) ready"
