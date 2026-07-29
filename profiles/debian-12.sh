# shellcheck shell=bash
# shellcheck disable=SC2034  # every value here is read by scripts/build.sh
# Debian 12 (Bookworm). Sourced by scripts/build.sh.
#
# The image URL points at the release channel rather than a pinned build, so a
# rebuild picks up the accumulated security fixes. What a given template was
# actually built from is recorded per build, not pinned here.

OS_FAMILY=debian
OS_VERSION=12
TEMPLATE_NAME=debian-12-template

# The generic variant, not genericcloud. This is a margin, not a requirement:
# genericcloud was checked and its cloud kernel does carry ata_piix, ahci and
# the CD-ROM and ISO9660 modules, so it would see the cloud-init seed Proxmox
# attaches as an IDE CD-ROM. What genericcloud drops is drivers for physical
# hardware, and generic is the superset of the two. The seed is the one thing
# whose absence is silent -- the guest boots and comes up with no user, no
# password and no SSH key -- so the variant that cannot run short of drivers is
# worth about 90 MB of download here. generic is also what these templates were
# built and verified with.
IMAGE_URL=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
CHECKSUM_URL=https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS
CHECKSUM_ALGO=sha512
# gnu: "<hash>  <name>". Red Hat family images publish "<ALGO> (<name>) = <hash>".
CHECKSUM_FORMAT=gnu

# Guest admin account. Must match the cloud image's own default user so that
# cloud-init and the sudoers drop-in name the same account. The platform sends
# the same name as the cloud-init user, so the template alone does not decide it.
CIUSER=debian

# The group that grants sudo. The sudo rule targets the group rather than the
# account so that it still applies if the platform ever hands cloud-init a
# different user name; a rule naming an absent account would leave cloud-init's
# passwordless rule as the last match.
SUDO_GROUP=sudo

# Broadwell-era baseline. Distributions that raise their ISA floor need a higher
# model here or they will not boot.
CPU_TYPE=x86-64-v2-AES

# The guest agent is what the platform uses to read the VM's SSH host keys and
# set its password; the rest is what somebody expects to find on a machine they
# were given. Disk only, no resident cost. The Debian cloud image ships neither
# the guest agent nor logrotate, so both are named here rather than assumed.
GUEST_PACKAGES="qemu-guest-agent,git,vim,nano,tmux,less,htop,ncdu,jq,rsync,unzip,zip,curl,wget,bash-completion,file,tree,psmisc,lsof,iproute2,traceroute,netcat-openbsd,logrotate,ca-certificates,dnsutils"

# No TMP_ON_DISK: this image carries no tmp.mount unit at all, so /tmp is already
# a directory on the root filesystem. The memory-sized tmpfs arrives in Debian 13.

# No SSHD_DROPIN_REMOVE: the Debian cloud image leaves /etc/ssh/sshd_config.d
# empty, and its own PasswordAuthentication comes after the Include line, so the
# 01- drop-in is the first value sshd obtains and wins.
