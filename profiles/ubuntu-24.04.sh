# shellcheck shell=bash
# shellcheck disable=SC2034  # every value here is read by scripts/build.sh
# Ubuntu 24.04 LTS (Noble Numbat). Sourced by scripts/build.sh.
#
# The image URL points at the release channel rather than a pinned build, so a
# rebuild picks up the accumulated security fixes. What a given template was
# actually built from is recorded per build, not pinned here.

OS_FAMILY=ubuntu
OS_VERSION=24.04
TEMPLATE_NAME=ubuntu-2404-template

IMAGE_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
CHECKSUM_URL=https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
CHECKSUM_ALGO=sha256
# gnu: "<hash>  <name>". Red Hat family images publish "<ALGO> (<name>) = <hash>".
CHECKSUM_FORMAT=gnu

# Guest admin account. Must match the cloud image's own default user so that
# cloud-init and the sudoers drop-in name the same account. The platform sends
# the same name as the cloud-init user, so the template alone does not decide it.
CIUSER=ubuntu

# The group that grants sudo. The sudo rule targets the group rather than the
# account so that it still applies if the platform ever hands cloud-init a
# different user name; a rule naming an absent account would leave cloud-init's
# passwordless rule as the last match.
SUDO_GROUP=sudo

# Broadwell-era baseline. Distributions that raise their ISA floor need a higher
# model here or they will not boot.
CPU_TYPE=x86-64-v2-AES

# The cloud image ships without the guest agent, and the platform needs it to
# read the guest's SSH host keys and to set the account password.
# The guest agent is what the platform uses to read the VM's SSH host keys and
# set its password; the rest is what somebody expects to find on a machine they
# were given. Disk only, no resident cost.
GUEST_PACKAGES="qemu-guest-agent,git,vim,nano,tmux,less,htop,ncdu,jq,rsync,unzip,zip,curl,wget,bash-completion,file,tree,psmisc,lsof,iproute2,traceroute,netcat-openbsd,logrotate,ca-certificates,dnsutils"

# Ubuntu cloud images ship PasswordAuthentication=no in this drop-in. Password
# SSH is enabled in the guest because who may use it is decided at the SSH
# gateway, not here.
SSHD_DROPIN_REMOVE=/etc/ssh/sshd_config.d/60-cloudimg-settings.conf
