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
# This gate loads them exactly the way the build does, through the same function,
# so that a green check means the build will get the same values. Grepping for an
# assignment would pass an empty value and an assignment inside a branch that
# never runs, and fail an exported one.
# shellcheck source=scripts/profile-vars.sh
. scripts/profile-vars.sh
reserved_alt=$(printf '%s' "$PROFILE_RESERVED_VARS" | tr ' ' '|')
profile_fail=0
for profile in profiles/*.sh; do
  [ -e "$profile" ] || continue

  mapfile -t fields < <(profile_load "$profile")
  if [ "${#fields[@]}" -ne "$(profile_declared_count)" ]; then
    echo "verify: $profile did not load cleanly (an early exit, or a value containing a newline)" >&2
    profile_fail=1
    continue
  fi
  if ! problems=$(profile_validate fields); then
    printf 'verify: %s %s\n' "$profile" "$problems" >&2
    profile_fail=1
  fi

  if grep -nE "^[[:space:]]*(export[[:space:]]+|readonly[[:space:]]+)?(${reserved_alt})=" "$profile"; then
    echo "verify: $profile assigns a name that belongs to the builder (above)" >&2
    profile_fail=1
  fi
done
[ "$profile_fail" -eq 0 ] || { echo "verify: profile check failed" >&2; exit 1; }

# Publication hygiene: no references to paths this repository does not contain,
# none to a private tree or a vault, no internal process tokens. Enforced here because two manual scrubs
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
