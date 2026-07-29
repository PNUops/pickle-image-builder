#!/usr/bin/env bash
# Address-hygiene gate. Sourced by scripts/verify.sh.
#
# Why it exists separately from hygiene.sh: that gate deliberately strips IPv4
# literals from a line before testing it, so a real deployment address sails
# straight through. This repo is published and its recipes talk about addresses,
# so every literal here has to be a documentation address or an unroutable
# constant. Deployment values arrive as build variables instead.
#
# Scope: IPv4 literals. The guests this recipe builds run on an IPv4-only
# network and the bridges carrying them have IPv6 disabled, so an IPv6 literal
# would be a documentation example rather than a deployment address; a pattern
# loose enough to catch one also catches clock times and diagram syntax.
#
# Usage: addr_hygiene_selftest
#        addr_hygiene_check

# Documentation ranges (RFC 5737) plus the constants that name no host.
addr_hygiene_allowed() {
  case "$1" in
    192.0.2.*|198.51.100.*|203.0.113.*) return 0 ;;   # RFC 5737 documentation
    127.*|169.254.*) return 0 ;;                      # loopback, link-local
    0.0.0.0|255.255.255.255) return 0 ;;
  esac
  return 1
}

# Files to scan: everything tracked except the two gate scripts, which carry the
# fixtures they test themselves with.
addr_hygiene_files() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  git -C "$root" ls-files -z | grep -zvE '^scripts/(addr-)?hygiene\.sh$'
}

addr_hygiene_check() {
  local rc=0 hit addr
  local -a files

  # Fail closed: an empty file list means the scan did not run, which must never
  # read as "clean".
  mapfile -d '' -t files < <(addr_hygiene_files) || true
  if [ "${#files[@]}" -eq 0 ]; then
    echo "addr-hygiene: no files to scan — is this a git worktree?" >&2
    return 1
  fi

  # A file grep cannot read produces silence rather than a warning, which is the
  # same shape as a clean scan. Refuse it instead.
  local binary textlist f
  local -a readable=()
  # An empty file has no line to match, so it never appears in a grep listing;
  # counting it as unreadable would accuse a .gitkeep of being a binary.
  for f in "${files[@]}"; do
    [ -s "$f" ] && readable+=("$f")
  done
  textlist="$(mktemp)"
  if [ "${#readable[@]}" -gt 0 ]; then
    printf '%s\0' "${readable[@]}" | xargs -0 grep -lI '' 2>/dev/null | sort > "$textlist" || true
  fi
  binary=$(printf '%s\n' "${readable[@]:-}" | sort | comm -23 - "$textlist" | grep -v '^$' || true)
  rm -f "$textlist"
  if [ -n "$binary" ]; then
    echo "addr-hygiene: file the scan cannot read:" >&2
    echo "$binary" >&2
    rc=1
  fi

  while IFS= read -r hit; do
    addr=${hit##*:}
    addr_hygiene_allowed "$addr" && continue
    echo "addr-hygiene: non-documentation IPv4 literal (use RFC 5737): $hit" >&2
    rc=1
  done < <(printf '%s\0' "${files[@]}" \
    | xargs -0 grep -HoIE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null || true)

  [ "$rc" -eq 0 ] && echo "addr-hygiene OK"
  return "$rc"
}

# Proves the gate still DETECTS, end to end: it builds a throwaway git repo and
# runs the real check over real files, so file enumeration and the grep are
# exercised, not just the classifier. A gate that only ever passes is worthless.
# shellcheck disable=SC2030,SC2031  # the checks run in subshells by design; the
# variables they read are assigned here and never written back.
addr_hygiene_selftest() {
  local tmp rc=0 self line
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/addr-hygiene.sh"
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/scripts"
  cp "$self" "$tmp/scripts/addr-hygiene.sh"
  git -C "$tmp" init -q
  git -C "$tmp" config user.email addr@example.invalid
  git -C "$tmp" config user.name addr

  while IFS= read -r line; do
    printf '%s\n' "$line" > "$tmp/sample.txt"
    git -C "$tmp" add -A >/dev/null 2>&1
    if ( cd "$tmp" && . scripts/addr-hygiene.sh && addr_hygiene_check ) >/dev/null 2>&1; then
      echo "addr-hygiene selftest: no longer detected: $line" >&2
      rc=1
    fi
  done <<'SAMPLES'
gateway reachable at 10.0.0.1
bridge address 172.16.31.9 on the host
public relay 198.18.7.4 forwards the port
nameserver 8.8.8.8
SAMPLES

  # The opposite direction: documentation addresses and constants must pass, or
  # the gate becomes something people work around.
  cat > "$tmp/sample.txt" <<'CLEAN'
example target 192.0.2.23 and 198.51.100.7 and 203.0.113.99
bind 0.0.0.0 or loopback 127.0.0.1 or the resolver stub 127.0.0.53
the hosts convention 127.0.1.1, link-local 169.254.169.254, mask 255.255.255.255
libguestfs 1.54.1 and contract v0.27.0 are not addresses
CLEAN
  git -C "$tmp" add -A >/dev/null 2>&1
  if ! ( cd "$tmp" && . scripts/addr-hygiene.sh && addr_hygiene_check ) >/dev/null 2>&1; then
    echo "addr-hygiene selftest: false positive on legitimate content" >&2
    rc=1
  fi

  # The unreadable-file path, which the check added and nothing exercised.
  printf 'clean line\n' > "$tmp/sample.txt"
  printf '\000\001\002binary\000' > "$tmp/blob.bin"
  : > "$tmp/empty-file"
  git -C "$tmp" add -A >/dev/null 2>&1
  if ( cd "$tmp" && . scripts/addr-hygiene.sh && addr_hygiene_check ) >/dev/null 2>&1; then
    echo "addr-hygiene selftest: a file the scan cannot read was not reported" >&2
    rc=1
  fi
  rm -f "$tmp/blob.bin"
  git -C "$tmp" add -A >/dev/null 2>&1
  if ! ( cd "$tmp" && . scripts/addr-hygiene.sh && addr_hygiene_check ) >/dev/null 2>&1; then
    echo "addr-hygiene selftest: an empty file was reported as unreadable" >&2
    rc=1
  fi

  rm -rf "$tmp"
  [ "$rc" -eq 0 ] && echo "addr-hygiene selftest OK"
  return "$rc"
}
