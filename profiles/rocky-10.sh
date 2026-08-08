# shellcheck shell=bash
# shellcheck disable=SC2034  # every value here is read by scripts/build.sh
# Rocky Linux 10. Sourced by scripts/build.sh.
#
# The image URL points at the release channel rather than a pinned build, so a
# rebuild picks up the accumulated security fixes. What a given template was
# actually built from is recorded per build, not pinned here.

OS_FAMILY=rocky
OS_VERSION=10
TEMPLATE_NAME=rocky-10-template

# GenericCloud-Base: the plain partition layout. The LVM variant of the same
# image puts the root filesystem on a logical volume, which the platform's disk
# resize would then have to grow in two steps instead of one.
IMAGE_URL=https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2
CHECKSUM_URL=https://dl.rockylinux.org/pub/rocky/10/images/x86_64/CHECKSUM
CHECKSUM_ALGO=sha256
# bsd: "<ALGO> (<name>) = <hash>", the form the Red Hat family publishes. The
# GNU parser extracts zero lines from this file, which would fail the build late
# on a checksum file that was there all along.
CHECKSUM_FORMAT=bsd

# Guest admin account. Must match the cloud image's own default user so that
# cloud-init and the sudoers drop-in name the same account. The platform sends
# the same name as the cloud-init user, so the template alone does not decide it.
CIUSER=rocky

# The group that grants sudo. The Red Hat family uses wheel where the
# Debian family uses sudo; the build asserts it exists in the image.
SUDO_GROUP=wheel

# NOT the x86-64-v2-AES baseline the other profiles take. Rocky 10 follows
# RHEL 10 in raising its floor to x86-64-v3, and a guest below that floor does
# not fail at install time or print anything about the instruction set: the
# kernel stops immediately after the EDD probe, before it can log to any
# console, and the VM sits at a blank screen forever. Measured on this node
# (Broadwell, which supports v3): the identical disk hangs there under
# x86-64-v2-AES and reaches a running guest agent in 15 s under x86-64-v3.
# A node whose CPU is older than Haswell cannot host this template at all.
CPU_TYPE=x86-64-v3

# htop and ncdu are NOT here: the Red Hat family ships neither in BaseOS,
# AppStream or Extras, and the only source is EPEL. Adding a third-party
# repository to every VM built from this template is a bigger decision than two
# convenience tools, and it is not one a profile should make quietly.
# Otherwise the same set as the other profiles, under the names this family
# uses: vim-enhanced for vim, iproute for iproute2, nmap-ncat for
# netcat-openbsd, bind-utils for dnsutils. The locale pack is a package here
# rather than something locale-gen produces, and the build fails if ko_KR is
# missing afterwards, so it has to be named.
GUEST_PACKAGES="qemu-guest-agent,git,vim-enhanced,nano,tmux,less,jq,rsync,unzip,zip,curl,wget,bash-completion,file,tree,psmisc,lsof,iproute,traceroute,nmap-ncat,logrotate,ca-certificates,bind-utils,glibc-langpack-ko"

# Four things this family does that a template has to undo, none of them
# visible in a build that succeeds either way. Two stop the platform from
# finishing a VM at all, on the step that reads the guest's SSH host keys
# through the agent; the other two are worse, because nothing fails.
#
# First, this family's guest agent runs with an explicit allow list of RPCs
# (FILTER_RPC_ARGS in /etc/sysconfig/qemu-ga) and the file calls are not on it,
# so the read is refused by the agent itself. Only the three calls a file read
# needs are added. guest-exec stays blocked, which leaves these guests stricter
# than the Debian-family templates, where the agent filters nothing at all.
#
# Second, SELinux. The public host keys carry sshd_key_t just as the private
# ones do, and the agent runs as virt_qemu_ga_t, which has no read of that type
# by default; the file opens with EPERM on a mode-0644 file while the agent is
# root, and nothing is logged, because the rule that would have audited it is a
# dontaudit. The policy's own knob for this is
# virt_qemu_ga_read_nonsecurity_files -- sshd_key_t is a non_security_file_type
# in this policy, so the boolean covers it. virt_qemu_ga_manage_ssh does NOT:
# it grants ssh_home_t, which is a user's authorized_keys, and turning it on
# leaves the host-key read failing exactly as before.
#
# The boolean is set here, offline, and it persists: setsebool -P writes the
# policy store and rebuilds the binary policy, both of which are ordinary files
# in the image. Verified by booting a guest built this way and reading all three
# host keys through the agent after cloud-init had generated them.
#
# What the check afterwards may NOT use is getsebool, which answers from the
# running kernel: there is no SELinux inside the build appliance, so it reports
# the boolean as disabled on an image where the setting landed perfectly well,
# and the build fails on a guest that would have worked. semanage reads the
# policy store, which is the thing being written, and answers correctly with no
# kernel involved. It is in this image already.
#
# Third, the sudo group. SUDO_GROUP above is wheel and the group exists, which
# is all the build checks -- but cloud-init on this family does not put the
# default user in it. It creates the account with groups [adm,
# systemd-journal] and grants sudo through its own
# /etc/sudoers.d/90-cloud-init-users instead, so the platform's zz-pickle rule
# matches nobody and cloud-init's NOPASSWD line is the last one standing. The
# result is a VM whose sudo never asks for the password that the console
# presents as the sudo credential, and nothing anywhere reports a problem.
# Measured on a VM cloned from a template built without this step. The fix is
# to add wheel to the list cloud-init creates the user with, which is what
# SUDO_GROUP already claims to be: the group cloud-init puts the default user
# in. Fixing it in cloud-init's own configuration rather than by naming the
# account in sudoers keeps that property true if the platform ever hands
# cloud-init a different user name.
#
# Fourth, and the reason the third fix alone is not enough: this image writes
# "rocky ALL=(ALL) NOPASSWD: ALL" into /etc/sudoers itself, on the line AFTER
# the #includedir. Sudo takes the last rule that matches, and everything in
# /etc/sudoers.d is read where the include sits -- so that one line is the last
# match for this account no matter what any drop-in says, and zz-pickle cannot
# win by sorting late, which is the entire mechanism the platform's sudoers
# file relies on. It is in the Rocky 9 image at the same line number. The line
# is removed, and the file is checked afterwards for any surviving passwordless
# rule and then parsed, because the one edit here that can break a guest
# outright is an edit to /etc/sudoers.
#
# Every step re-reads what it wrote and fails the build if it is not there, so
# a future image that renames the setting, drops the boolean, ships different
# default groups or stops writing that sudoers line stops here rather than
# producing a template whose VMs cannot be provisioned, or can be but hand out
# a sudo that never asks.
GUEST_COMMAND="grep -q '^FILTER_RPC_ARGS=.*--allow-rpcs=' /etc/sysconfig/qemu-ga || { echo 'the guest agent no longer takes an allow list; re-derive this step' >&2; exit 1; }; sed -i '/^FILTER_RPC_ARGS=/ s/--allow-rpcs=/--allow-rpcs=guest-file-open,guest-file-close,guest-file-read,/' /etc/sysconfig/qemu-ga; grep -q '^FILTER_RPC_ARGS=.*--allow-rpcs=guest-file-open,guest-file-close,guest-file-read,' /etc/sysconfig/qemu-ga || { echo 'the guest agent allow list was not extended' >&2; exit 1; }; setsebool -P virt_qemu_ga_read_nonsecurity_files on; semanage boolean -l -C | grep -q 'virt_qemu_ga_read_nonsecurity_files (on' || { echo 'the guest agent SELinux boolean did not reach the policy store' >&2; exit 1; }; grep -q '^ *groups: .adm, systemd-journal.' /etc/cloud/cloud.cfg || { echo 'the cloud-init default user groups are not the list this step expects' >&2; exit 1; }; sed -i '/^ *groups: .adm, systemd-journal./s/]/, wheel]/' /etc/cloud/cloud.cfg; grep -q '^ *groups: .adm, systemd-journal, wheel.' /etc/cloud/cloud.cfg || { echo 'the cloud-init default user was not added to the sudo group' >&2; exit 1; }; grep -q '^rocky[[:space:]].*NOPASSWD' /etc/sudoers || { echo 'the image no longer grants the default user a passwordless sudo in /etc/sudoers; re-derive this step' >&2; exit 1; }; sed -i '/^rocky[[:space:]].*NOPASSWD/d' /etc/sudoers; grep -q '^[^#]*NOPASSWD' /etc/sudoers && { echo 'a passwordless sudo rule survives in /etc/sudoers' >&2; exit 1; }; visudo -cf /etc/sudoers"

# No SSHD_DROPIN_REMOVE. cloud-init writes PasswordAuthentication no into
# /etc/ssh/sshd_config.d/50-cloud-init.conf on this image, but sshd keeps the
# FIRST value it obtains for a keyword and the drop-in this build installs is
# numbered 01, so it is already the value that applies.
#
# No TMP_ON_DISK. This family leaves /tmp on the root filesystem and ships
# tmp.mount disabled, so there is no tmpfs to mask.
