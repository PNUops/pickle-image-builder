# shellcheck shell=bash
# shellcheck disable=SC2034  # every value here is read by scripts/build.sh
# Rocky Linux 9. Sourced by scripts/build.sh.
#
# The image URL points at the release channel rather than a pinned build, so a
# rebuild picks up the accumulated security fixes. What a given template was
# actually built from is recorded per build, not pinned here.

OS_FAMILY=rocky
OS_VERSION=9
TEMPLATE_NAME=rocky-9-template

# GenericCloud-Base: the plain partition layout. The LVM variant of the same
# image puts the root filesystem on a logical volume, which the platform's disk
# resize would then have to grow in two steps instead of one.
IMAGE_URL=https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
CHECKSUM_URL=https://dl.rockylinux.org/pub/rocky/9/images/x86_64/CHECKSUM
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

# The ordinary baseline, unlike the Rocky 10 profile: this release keeps the
# x86-64-v2 floor its predecessors had, and it was booted on this node under
# this model to confirm it rather than inferred from the next release raising
# the floor.
CPU_TYPE=x86-64-v2-AES

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

# Identical to the Rocky 10 profile, and for the same four reasons: this
# family's guest agent takes an explicit allow list of RPCs that excludes the
# file calls; SELinux then refuses virt_qemu_ga_t the read of sshd_key_t, which
# is what the public host keys carry; cloud-init does not put the default user
# in the sudo group this profile names; and the image writes a passwordless
# sudo rule for that user into /etc/sudoers below the include, where no drop-in
# can outrank it. The first two stop the platform on the step that collects a
# VM's host keys; the other two stop nothing and hand out a sudo that never
# asks. None is visible in a build that otherwise succeeds. The reasoning,
# including why virt_qemu_ga_manage_ssh is the wrong boolean and why the check
# cannot use getsebool, is written out in rocky-10.sh; it is the same text and
# is not repeated here. This release was measured separately: the allow list
# has the same shape, the boolean exists in its policy, its cloud-init creates
# the account with the same two groups, and the sudoers line sits at the same
# place in the file.
GUEST_COMMAND="grep -q '^FILTER_RPC_ARGS=.*--allow-rpcs=' /etc/sysconfig/qemu-ga || { echo 'the guest agent no longer takes an allow list; re-derive this step' >&2; exit 1; }; sed -i '/^FILTER_RPC_ARGS=/ s/--allow-rpcs=/--allow-rpcs=guest-file-open,guest-file-close,guest-file-read,/' /etc/sysconfig/qemu-ga; grep -q '^FILTER_RPC_ARGS=.*--allow-rpcs=guest-file-open,guest-file-close,guest-file-read,' /etc/sysconfig/qemu-ga || { echo 'the guest agent allow list was not extended' >&2; exit 1; }; setsebool -P virt_qemu_ga_read_nonsecurity_files on; semanage boolean -l -C | grep -q 'virt_qemu_ga_read_nonsecurity_files (on' || { echo 'the guest agent SELinux boolean did not reach the policy store' >&2; exit 1; }; grep -q '^ *groups: .adm, systemd-journal.' /etc/cloud/cloud.cfg || { echo 'the cloud-init default user groups are not the list this step expects' >&2; exit 1; }; sed -i '/^ *groups: .adm, systemd-journal./s/]/, wheel]/' /etc/cloud/cloud.cfg; grep -q '^ *groups: .adm, systemd-journal, wheel.' /etc/cloud/cloud.cfg || { echo 'the cloud-init default user was not added to the sudo group' >&2; exit 1; }; grep -q '^rocky[[:space:]].*NOPASSWD' /etc/sudoers || { echo 'the image no longer grants the default user a passwordless sudo in /etc/sudoers; re-derive this step' >&2; exit 1; }; sed -i '/^rocky[[:space:]].*NOPASSWD/d' /etc/sudoers; grep -q '^[^#]*NOPASSWD' /etc/sudoers && { echo 'a passwordless sudo rule survives in /etc/sudoers' >&2; exit 1; }; visudo -cf /etc/sudoers"

# No SSHD_DROPIN_REMOVE and no TMP_ON_DISK, for the reasons the Rocky 10 profile
# records: the 01 drop-in already wins over what cloud-init writes, and this
# family leaves /tmp on the root filesystem with tmp.mount disabled.
