# shellcheck shell=bash
# shellcheck disable=SC2034  # read by scripts/build.sh and scripts/verify.sh
# The fields an OS profile carries. Kept in one file because both the builder
# (which needs them at build time) and the verification gate (which checks
# profiles without a hypervisor to build on) read the same list; two copies
# would drift the day a field is added.
#
# A profile is shell, and the builder runs as root on the hypervisor, so a
# profile is executable code — it is loaded in an empty-environment subshell and
# only these names are carried back. Nothing a profile assigns can reach the
# builder's own variables.
PROFILE_REQUIRED_VARS="OS_FAMILY OS_VERSION TEMPLATE_NAME IMAGE_URL CHECKSUM_URL CHECKSUM_ALGO CIUSER CPU_TYPE GUEST_PACKAGES"
PROFILE_OPTIONAL_VARS="SSHD_DROPIN_REMOVE"

# Names that belong to the builder. A profile setting one of these is a mistake
# worth failing on even though the subshell already makes it harmless: it means
# the author believes profiles control the build.
PROFILE_RESERVED_VARS="TEMPLATE_VMID REBUILD PROFILE PROFILE_PATH REPO_ROOT STORAGE BRIDGE IMAGE_CACHE_DIR IMAGE_PATH IMAGE_FILE WORK_IMG DOWNLOAD_TMP SUM_CMD PROFILE_REQUIRED_VARS PROFILE_OPTIONAL_VARS PROFILE_RESERVED_VARS"
