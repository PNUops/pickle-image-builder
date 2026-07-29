#!/usr/bin/env bash
# Verification gate: shell lint + publication hygiene + address hygiene.
set -euo pipefail
cd "$(dirname "$0")/.."

mapfile -t scripts < <(find . -name '*.sh' -not -path './.git/*')
shellcheck "${scripts[@]}"

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
