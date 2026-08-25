#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ONECLICKVIRT_TESTING=1
export LXD_STATE_DIR
LXD_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$LXD_STATE_DIR"' EXIT

# shellcheck disable=SC1091 # The test sources the repository script through a computed path.
source "$ROOT_DIR/scripts/build_ipv6_network.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [ "$expected" = "$actual" ] || fail "$label: expected [$expected], got [$actual]"
}

assert_eq "2001:db8::1" "$(normalize_ipv6_address '2001:0db8:0:0::1')" "normalize IPv6"
assert_eq "2001:db8:abcd::10/120" "$(normalize_ipv6_interface '2001:0db8:abcd::10/120')" "normalize /120 interface"
assert_eq "2001:db8:abcd::/120" "$(normalize_ipv6_network '2001:db8:abcd::10/120')" "normalize /120 network"

if normalize_ipv6_address $'2001:db8::1\nwarning'; then
    fail "polluted IPv6 value must be rejected"
fi
if normalize_ipv6_interface 'inet6 2001:db8::1/64 scope global'; then
    fail "diagnostic IPv6 interface output must be rejected"
fi

state_path=$(state_file lxd_check_ipv6)
write_atomic_scalar "$state_path" "2001:db8::2"
assert_eq "2001:db8::2" "$(read_strict_ipv6_file "$state_path")" "read strict state"
printf '2001:db8::2\n2001:db8::3\n' >"$state_path"
if read_strict_ipv6_file "$state_path"; then
    fail "multi-line cached IPv6 state must be rejected"
fi

interfaces=$'2001:db8::1/64\n2001:db8:1::2/120'
assert_eq "2001:db8:1::2/120" "$(select_ipv6_interface '2001:db8:1::2' "$interfaces")" "select preferred interface"

candidate=$(random_ipv6_candidate '2001:db8::/127' '2001:db8::')
assert_eq "2001:db8::1" "$candidate" "generate /127 candidate"
if random_ipv6_candidate '2001:db8::1/128' '2001:db8::1'; then
    fail "/128 with its only address excluded must fail"
fi

mapfile -t candidates < <(generate_ipv6_candidates '2001:db8::/126' 20)
assert_eq "4" "${#candidates[@]}" "bounded /126 expansion"
assert_eq "2001:db8::" "${candidates[0]}" "first /126 address"
assert_eq "2001:db8::3" "${candidates[3]}" "last /126 address"

printf 'build_ipv6_network tests passed\n'
