#!/usr/bin/env bash
# Verification gate: shell lint + profile checks + publication and address hygiene.
set -euo pipefail
cd "$(dirname "$0")/.."

# find's exit status is invisible through a process substitution, so a partial
# walk would shorten the list and still lint clean. Materialising it first lets
# set -e see the failure.
listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT
find . -name '*.sh' -not -path './.git/*' -print0 > "$listing"
mapfile -d '' -t scripts < "$listing"
[ "${#scripts[@]}" -gt 0 ] || { echo "verify: no scripts found" >&2; exit 1; }
shellcheck "${scripts[@]}"

# Profiles are executable shell that the builder runs as root on a hypervisor.
# The builder only ever loads them in an empty-environment subshell, and this
# gate loads them the same way: testing the value a profile actually produces,
# rather than grepping for an assignment. A grep passes an empty value, an
# assignment inside a branch that never runs, and fails an exported one.
# shellcheck source=scripts/profile-vars.sh
. scripts/profile-vars.sh
reserved_alt=$(printf '%s' "$PROFILE_RESERVED_VARS" | tr ' ' '|')
profile_fail=0
for profile in profiles/*.sh; do
  [ -e "$profile" ] || continue

  # shellcheck disable=SC2016  # the body runs in the child, not here
  missing=$(env -i PATH=/usr/bin:/bin bash --noprofile --norc -c '
    set -euo pipefail
    . "$1"
    . "$2"
    for v in $PROFILE_REQUIRED_VARS; do
      [ -n "${!v-}" ] || printf "%s " "$v"
    done
  ' _ "$profile" scripts/profile-vars.sh) || {
    echo "verify: $profile failed to load" >&2
    profile_fail=1
    continue
  }
  if [ -n "$missing" ]; then
    echo "verify: $profile leaves these unset: $missing" >&2
    profile_fail=1
  fi

  if grep -nE "^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?(${reserved_alt})=" "$profile"; then
    echo "verify: $profile assigns a name that belongs to the builder (above)" >&2
    profile_fail=1
  fi
done
[ "$profile_fail" -eq 0 ] || { echo "verify: profile check failed" >&2; exit 1; }

# Publication hygiene: no documentation-repo references, no private-repo or vault
# references, no internal process tokens. Enforced here because two manual scrubs
# both missed real violations.
# shellcheck source=scripts/hygiene.sh
. scripts/hygiene.sh   # cwd is the repo root (set above)
hygiene_selftest
hygiene_check public

# Address hygiene: deployment addresses never enter a published recipe.
# shellcheck source=scripts/addr-hygiene.sh
. scripts/addr-hygiene.sh
addr_hygiene_selftest
addr_hygiene_check

echo "image-builder verify OK (${#scripts[@]} scripts)"
