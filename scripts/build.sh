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
GUEST_COMMAND="${PV[GUEST_COMMAND]:-}"
TMP_ON_DISK="${PV[TMP_ON_DISK]:-no}"
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
INSTALL_SCRIPT=""
APT_TIMER_CONF=""
SUDOCHECK_SCRIPT=""
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
    ${ISSUE_TEXT:+"$ISSUE_TEXT"} \
    ${INSTALL_SCRIPT:+"$INSTALL_SCRIPT"} \
    ${SUDOCHECK_SCRIPT:+"$SUDOCHECK_SCRIPT"}
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
# Syntax is all it validates, though, and every way this rule fails to bite
# leaves it syntactically perfect, so the effectiveness check below is what
# actually decides whether the image ships.
SUDOERS_CONF="$(mktemp)"
cat > "$SUDOERS_CONF" <<SUDO
%${SUDO_GROUP} ALL=(ALL:ALL) PASSWD:ALL
Defaults passwd_tries=3
Defaults timestamp_timeout=5
SUDO

# Does that rule actually make sudo ask? Two ways it does not, both of which
# leave every file well-formed and every check above green:
#
#   - cloud-init does not put the default user in this group, so the rule
#     matches nobody and cloud-init's own passwordless rule stays the last match
#   - the image carries a rule BELOW the include directive in /etc/sudoers. Sudo
#     reads /etc/sudoers.d where the directive sits and the last match wins, so
#     such a line beats every drop-in and sorting a name to the end is void on
#     that distribution
#
# Neither fails anything. The VM boots, sudo works, and it never asks for the
# password the console calls the sudo credential. So the image is put into the
# state a booted clone reaches and sudo itself is asked.
#
# Asking sudo inside the build appliance is worth something only with a control.
# Any environmental reason for sudo to fail -- a broken binary, a refused
# syscall, no pty -- looks exactly like "a password was demanded", which is the
# answer this check wants to hear, so a bare `sudo -n` would pass a giveaway
# image. The check therefore first grants the same user a passwordless rule and
# requires sudo to say yes to it. Only an environment that can say yes is
# allowed to say no.
SUDOCHECK_SCRIPT="$(mktemp)"
cat > "$SUDOCHECK_SCRIPT" <<'SUDOCHECK'
#!/bin/sh
# Managed by the image builder. Runs inside the image, never on the host.
u="$1"
g="$2"

DROPIN=/etc/sudoers.d/90-cloud-init-users
CONTROL=/etc/sudoers.d/zzzz-pickle-sudo-check

say() { echo "sudo check: $*" >&2; }

# The interpreter that owns the cloud-init library, which is not always the one
# called python3.
ci_python() {
  cip=$(command -v cloud-init 2>/dev/null) || cip=
  if [ -n "$cip" ]; then
    p=$(sed -n '1s/^#![[:space:]]*//p' "$cip" | awk '{print $1}')
    if [ -n "$p" ] && [ -x "$p" ]; then echo "$p"; return 0; fi
  fi
  command -v python3 2>/dev/null
}

# Never as root: root has its own rule in every sudoers, so asking as root
# answers nothing about the default user.
as_user() {
  setpriv --reuid="$uid" --regid="$gid" --init-groups --reset-env \
    env LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    sudo -n true >/dev/null 2>&1
}

checks() (
  set -e

  py=$(ci_python)
  [ -n "$py" ] || { say "the image has no python interpreter to read its cloud-init configuration with"; exit 1; }

  # cloud-init's own merge of /etc/cloud/cloud.cfg and /etc/cloud/cloud.cfg.d,
  # rather than a second implementation of that merge living here.
  cfg=$("$py" - <<'PY'
import sys
from cloudinit import util
c = util.read_conf_with_confd("/etc/cloud/cloud.cfg")
d = (c.get("system_info") or {}).get("default_user") or {}
if not d:
    sys.exit("system_info.default_user is not set")
groups = d.get("groups") or []
if isinstance(groups, str):
    groups = groups.replace(",", " ").split()
rules = d.get("sudo") or []
if isinstance(rules, str):
    rules = [rules]
print("NAME=%s" % (d.get("name") or ""))
print("GROUPS=%s" % " ".join(str(x) for x in groups))
for r in rules:
    r = str(r).strip()
    if r:
        print("RULE=%s" % r)
PY
  ) || { say "could not read the image's cloud-init default-user configuration"; exit 1; }

  name=$(printf '%s\n' "$cfg" | sed -n 's/^NAME=//p')
  groups=$(printf '%s\n' "$cfg" | sed -n 's/^GROUPS=//p')
  rules=$(printf '%s\n' "$cfg" | sed -n 's/^RULE=//p')

  if [ "$name" != "$u" ]; then
    say "the image's cloud-init default user is '$name', the profile names '$u'"
    exit 1
  fi
  case " $groups " in
    *" $g "*) ;;
    *) say "cloud-init puts '$u' in [$groups], which does not include '$g': the sudoers rule matches nobody"
       exit 1 ;;
  esac
  if id "$u" >/dev/null 2>&1; then
    say "the image already carries a user named '$u', so there is none to create and test with"
    exit 1
  fi

  # The state a booted clone reaches: the default user in the groups cloud-init
  # gives it, and cloud-init's own passwordless rule where cloud-init writes it.
  # Under the real account name, because a distribution's giveaway rule can name
  # the account rather than a group and a stand-in name would walk past it.
  add=
  for grp in $groups; do
    getent group "$grp" >/dev/null 2>&1 && add="${add:+$add,}$grp"
  done
  useradd -m -s /bin/sh ${add:+-G "$add"} "$u"
  printf '%s\n' "$rules" | while IFS= read -r r; do
    [ -n "$r" ] && printf '%s %s\n' "$u" "$r"
  done > "$DROPIN"
  chmod 440 "$DROPIN"

  uid=$(id -u "$u")
  gid=$(id -g "$u")

  # The control. It sorts after everything the build wrote, so sudo answering
  # "no password needed" to it proves this environment is able to say yes.
  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$u" > "$CONTROL"
  chmod 440 "$CONTROL"
  if ! as_user; then
    say "sudo refused even with a passwordless rule in place, so this check cannot judge the image"
    exit 1
  fi
  rm -f "$CONTROL"

  if as_user; then
    say "'$u' obtains root with no password: the rule the build wrote is not the last match"
    exit 1
  fi
  # Told apart from the case above by asking sudo what the user may do at all. A
  # VM whose sudo refuses everyone is wrong in the other direction: the console
  # names the VM password as the sudo credential.
  if ! sudo -l -U "$u" >/dev/null 2>&1; then
    say "'$u' may not run sudo at all"
    exit 1
  fi
  exit 0
)

BK=$(mktemp -d)
cp -a /etc/sudoers.d "$BK/sudoers.d"
for f in passwd shadow group gshadow subuid subgid; do
  [ -f "/etc/$f" ] && cp -a "/etc/$f" "$BK/$f"
done

rc=0
checks || rc=1

# The image ships without any of it. The account files go back verbatim rather
# than being unwound command by command, because a half-removed account is the
# same kind of silent defect this check exists to catch.
userdel -r "$u" >/dev/null 2>&1
rm -rf /etc/sudoers.d
cp -a "$BK/sudoers.d" /etc/sudoers.d
for f in passwd shadow group gshadow subuid subgid; do
  [ -f "$BK/$f" ] && cp -a "$BK/$f" "/etc/$f"
done
rm -rf "$BK" "/home/$u" "/var/mail/$u" "/var/spool/mail/$u" \
       /var/db/sudo/lectured /var/lib/sudo/ts /var/lib/sudo/lectured

if id "$u" >/dev/null 2>&1; then
  say "the check's own account '$u' survived cleanup"
  rc=1
fi
for leftover in "$DROPIN" "$CONTROL" "/home/$u"; do
  if [ -e "$leftover" ]; then
    say "the check left $leftover behind"
    rc=1
  fi
done
exit "$rc"
SUDOCHECK

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
# A distribution can need something no field describes. The Red Hat family ships
# its guest agent with the file and exec calls refused, and the platform reads
# each VM's SSH host keys through exactly those, so a template built without
# lifting that produces VMs the provisioner cannot finish. The value is ordinary
# printable text like every other field and runs inside the image, never here.
if [ -n "$GUEST_COMMAND" ]; then
  customize+=(--run-command "$GUEST_COMMAND")
fi
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

# Everything generated above goes into the image in one place, and a script
# inside the guest puts each piece where that distribution keeps it. Uploading
# straight to the final paths meant the recipe had to know each layout in
# advance: the boot loader takes drop-ins on one family and only a single file
# on the other, and a path belonging to a package manager the image does not
# have is not somewhere to write at all.
INSTALL_SCRIPT="$(mktemp)"
cat > "$INSTALL_SCRIPT" <<'INSTALL'
#!/bin/sh
set -e
cd /etc/pickle/staging

put() { mkdir -p "$(dirname "$2")"; install -m "$3" "$1" "$2"; }

put sshd.conf /etc/ssh/sshd_config.d/01-pickle.conf 644
put sudoers /etc/sudoers.d/zz-pickle 440
visudo -cf /etc/sudoers.d/zz-pickle

# One family sources drop-ins after the file and ships its own settings in one,
# so a plain append would lose to them. The other reads only the file.
if [ -d /etc/default/grub.d ]; then
  put grub.cfg /etc/default/grub.d/99-pickle.cfg 644
else
  cat grub.cfg >> /etc/default/grub
fi

put cloud-datasource.cfg /etc/cloud/cloud.cfg.d/99-pickle-datasource.cfg 644
put sysctl.conf /etc/sysctl.d/99-pickle.conf 644
put journald.conf /etc/systemd/journald.conf.d/99-pickle.conf 644
put coredump.conf /etc/systemd/coredump.conf.d/99-pickle.conf 644
put image.json /etc/pickle/image.json 644
put issue /etc/issue 644
put issue /etc/issue.net 644

# Only where that package manager lives.
[ -d /etc/apt/apt.conf.d ] && put apt.conf /etc/apt/apt.conf.d/99-pickle 644
[ -d /etc/needrestart ] && put needrestart.conf /etc/needrestart/conf.d/99-pickle.conf 644
for t in apt-daily apt-daily-upgrade; do
  [ -f "/usr/lib/systemd/system/$t.timer" ] &&
    put timer.conf "/etc/systemd/system/$t.timer.d/99-pickle.conf" 644
done

# One family runs scripts at login time; the other reads static text.
if [ -d /etc/update-motd.d ]; then
  put motd /etc/update-motd.d/00-pickle 755
  chmod -x /etc/update-motd.d/*motd-news* /etc/update-motd.d/*landscape* \
           /etc/update-motd.d/*esm* /etc/update-motd.d/*contract* \
           /etc/update-motd.d/*release-upgrade* 2>/dev/null || true
else
  sh motd > /etc/motd.d-pickle-text 2>/dev/null || true
  put /etc/motd.d-pickle-text /etc/motd.d/00-pickle 644
  rm -f /etc/motd.d-pickle-text
fi

update-grub >/dev/null 2>&1 || grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
cd /
rm -rf /etc/pickle/staging
INSTALL

customize+=(
  --mkdir /etc/pickle/staging
  --upload "${SSHD_CONF}:/etc/pickle/staging/sshd.conf"
  --upload "${SUDOERS_CONF}:/etc/pickle/staging/sudoers"
  --upload "${GRUB_CONF}:/etc/pickle/staging/grub.cfg"
  --upload "${CLOUDCFG_CONF}:/etc/pickle/staging/cloud-datasource.cfg"
  --upload "${LIMITS_CONF}:/etc/pickle/staging/sysctl.conf"
  --upload "${JOURNALD_CONF}:/etc/pickle/staging/journald.conf"
  --upload "${COREDUMP_CONF}:/etc/pickle/staging/coredump.conf"
  --upload "${APT_CONF}:/etc/pickle/staging/apt.conf"
  --upload "${NEEDRESTART_CONF}:/etc/pickle/staging/needrestart.conf"
  --upload "${APT_TIMER_CONF}:/etc/pickle/staging/timer.conf"
  --upload "${MANIFEST_BODY}:/etc/pickle/staging/image.json"
  --upload "${MOTD_SCRIPT}:/etc/pickle/staging/motd"
  --upload "${ISSUE_TEXT}:/etc/pickle/staging/issue"
  --upload "${INSTALL_SCRIPT}:/etc/pickle/staging/install.sh"
  --run-command "sh /etc/pickle/staging/install.sh"
  # Machine identity. Clones must not share one: systemd derives the journal id
  # and the default DHCP client id from it, and a duplicate makes two VMs look
  # like one wherever those are used. The systemd contract for an image is the
  # literal word rather than an empty file, and the D-Bus copy is a separate
  # file on these distributions rather than a link to the first.
  --run-command "printf 'uninitialized\\n' > /etc/machine-id &&
                 rm -f /var/lib/dbus/machine-id &&
                 rm -rf /var/lib/cloud/instance /var/lib/cloud/instances /var/lib/cloud/data"
  # Last, so that everything able to write a sudoers rule -- the package install
  # above included -- has already written. Still in this pass rather than a
  # fourth one: the check creates an account and puts the files back afterwards,
  # and the relabelling pass that follows repairs any security label that
  # restoring a file cost.
  --upload "${SUDOCHECK_SCRIPT}:/pickle-sudo-check.sh"
  --run-command "sh /pickle-sudo-check.sh $(printf '%q' "$CIUSER") $(printf '%q' "$SUDO_GROUP")"
  --delete /pickle-sudo-check.sh
)

# Where /tmp lives. A distribution that mounts it as a tmpfs sizes it from RAM,
# and on the small guests this platform hands out that budget is shared with
# everything the student is running: an archive extracted into /tmp is spent
# memory, the process is killed for it, and df reports the disk almost empty the
# whole time. Nothing in that failure names /tmp, so the guest is given the
# ordinary directory instead and the disk quota becomes the only limit.
#
# Masking is the systemd way to say a mount unit must not run. Written as the
# link rather than through systemctl because the image is not booted here and
# systemctl treats an offline tree as a special case. The unit is required to
# exist: a profile asking for this on an image that never had the tmpfs is a
# stale assumption, and finding out at build time beats finding out never.
if [ "$TMP_ON_DISK" = yes ]; then
  customize+=(
    --run-command "test -e /usr/lib/systemd/system/tmp.mount || test -e /lib/systemd/system/tmp.mount ||
                   { echo 'TMP_ON_DISK is set but this image has no tmp.mount unit' >&2; exit 1; }
                   ln -sf /dev/null /etc/systemd/system/tmp.mount"
  )
fi

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
# Security labels, where the guest has them. Installing packages writes files
# from outside the guest's own policy, so they arrive unlabelled, and a guest
# that cannot execute its own dynamic loader starts no service at all. Letting
# the guest relabel itself on first boot does not work either: the program that
# would do the relabelling is one of the files it cannot execute. So it happens
# here, after everything else has written.
virt-customize -a "$WORK_IMG" --run-command \
  'if [ -f /etc/selinux/config ] && command -v setfiles >/dev/null 2>&1; then
     setfiles -F /etc/selinux/targeted/contexts/files/file_contexts / >/dev/null 2>&1 || true
     rm -f /.autorelabel
   fi'

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
