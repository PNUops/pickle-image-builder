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
PROFILE_REQUIRED_VARS="OS_FAMILY OS_VERSION TEMPLATE_NAME IMAGE_URL CHECKSUM_URL CHECKSUM_ALGO CIUSER SUDO_GROUP CPU_TYPE GUEST_PACKAGES"
PROFILE_OPTIONAL_VARS="SSHD_DROPIN_REMOVE CHECKSUM_FORMAT GUEST_COMMAND"

# Names the builder decides. A profile setting one of these is a mistake worth
# failing on even though the subshell already makes it harmless: it means the
# author believes profiles control the build. The list names the ones a profile
# author might plausibly reach for, not every variable the builder happens to
# use.
PROFILE_RESERVED_VARS="TEMPLATE_VMID REBUILD PROFILE PROFILE_PATH REPO_ROOT STORAGE BRIDGE IMAGE_CACHE_DIR IMAGE_PATH IMAGE_FILE WORK_IMG DOWNLOAD_TMP SUM_CMD PROFILE_REQUIRED_VARS PROFILE_OPTIONAL_VARS PROFILE_RESERVED_VARS"

# Reads a profile and prints one "NAME=value" line per declared field.
#
# A profile is shell that the builder runs as root on a hypervisor, so it is
# never sourced into the caller: the empty environment keeps a field the profile
# forgot from being inherited from whoever ran the build, and the field list is
# loaded after the profile so a profile cannot shrink it to hide a gap. The
# builder and the verification gate both call this, because two copies of a
# loader drift and then the gate stops testing what the build does.
#
# The caller must compare the line count against the declared fields: a profile
# that exits early, or that redefines printf, prints fewer lines and would
# otherwise read as complete.
profile_load() {
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  # shellcheck disable=SC2016  # the body runs in the child, not here
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin bash --noprofile --norc -c '
    set -euo pipefail
    . "$1"
    . "$2"
    for v in $PROFILE_REQUIRED_VARS $PROFILE_OPTIONAL_VARS; do
      command printf "%s=%s\n" "$v" "${!v-}"
    done
  ' _ "$1" "$self"
}

# Checks the fields a profile produced. Prints one line per problem and returns
# non-zero if there was any. Both the builder and the gate call this, so that a
# green check means the build will accept the same profile: a rule that lives in
# only one of them is a rule the other stops enforcing.
profile_validate() {
  local -n _fields="$1"
  local rc=0 name value line
  local -A got=()
  for line in "${_fields[@]}"; do got["${line%%=*}"]="${line#*=}"; done

  for name in $PROFILE_REQUIRED_VARS; do
    if [ -z "${got[$name]+set}" ]; then
      echo "does not set $name"; rc=1
    elif [ -z "${got[$name]}" ]; then
      echo "leaves $name empty"; rc=1
    fi
  done

  # Every value reaches a generated file. The manifest is JSON, where a quote or
  # a backslash produces a file that parses as nothing and a control character is
  # illegal outright; the rest land in guest configuration or a guest command.
  for name in $PROFILE_REQUIRED_VARS $PROFILE_OPTIONAL_VARS; do
    value="${got[$name]-}"
    case "$value" in
      *'"'*|*\\*) echo "$name contains a quote or backslash"; rc=1 ;;
      *[!\ -~]*)   echo "$name contains a control or non-ASCII character"; rc=1 ;;
    esac
  done

  # The algorithm names a command, so it stays a bare word: anything else lets a
  # profile field decide which binary hashes the image.
  case "${got[CHECKSUM_ALGO]-}" in
    ''|*[!a-z0-9]*) echo "CHECKSUM_ALGO must be a bare name such as sha256"; rc=1 ;;
  esac
  case "${got[CHECKSUM_FORMAT]-gnu}" in
    ''|gnu|bsd) : ;;
    *) echo "CHECKSUM_FORMAT must be gnu or bsd"; rc=1 ;;
  esac
  return "$rc"
}

# The number of lines a healthy profile_load prints.
profile_declared_count() {
  printf '%s %s' "$PROFILE_REQUIRED_VARS" "$PROFILE_OPTIONAL_VARS" | wc -w
}
