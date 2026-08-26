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

assert_eq "2a14:7c0:1000::/38" "$(ipv6_allocation_network '2a14:7c0:1002:10f8::1/38')" "normalize non-nibble routed prefix"
assert_eq "2606:4700::/127" "$(ipv6_allocation_network '2606:4700::1/127')" "retain /127 routed prefix"
assert_eq "2606:4700::/64" "$(ipv6_allocation_network '2606:4700::1/64')" "retain SLAAC /64 shape"
if ipv6_allocation_network '2606:4700::1/128' >/dev/null; then
    fail "/128 was accepted as an IPv6 allocation pool"
fi
if ipv6_pool_has_extra_address '2606:4700::1/128' '2606:4700::1'; then
    fail "/128 was reported to have an extra address"
fi
if ! ipv6_pool_has_extra_address '2606:4700::/127' '2606:4700::'; then
    fail "/127 was rejected despite having one remaining address"
fi
export LXD_IPV6_ROUTED_PREFIX='2a14:7c0:1002:2000::/64'
assert_eq "2a14:7c0:1002:2000::/64" "$(ipv6_allocation_network '2606:4700::1/128')" "explicit routed prefix overrides host /128"
unset LXD_IPV6_ROUTED_PREFIX

printf '%s\n' routed >"$LXD_STATE_DIR/lxd_ipv6_mode"
configure_ipv6_nat66_fallback >/dev/null
assert_eq routed "$(cat "$LXD_STATE_DIR/lxd_ipv6_mode")" "fallback preserves existing routed mode"
rm -f "$LXD_STATE_DIR/lxd_ipv6_mode"
configure_ipv6_nat66_fallback >/dev/null
assert_eq nat66 "$(cat "$LXD_STATE_DIR/lxd_ipv6_mode")" "fallback records NAT66 mode"

# shellcheck disable=SC2329 # Called indirectly by the sourced network helpers.
ip() {
    case "$*" in
    "-o -6 addr show dev he-ipv6 scope global")
        printf '%s\n' '7: he-ipv6    inet6 2606:4700::1/64 scope global'
        ;;
    *)
        command ip "$@"
        ;;
    esac
}
export LXD_IPV6_UPLINK=he-ipv6
assert_eq "he-ipv6" "$(ipv6_uplink_interface)" "explicit tunnel uplink"
assert_eq "2606:4700::1/64" "$(ipv6_uplink_cidr he-ipv6 2606:4700::1)" "tunnel address selection"
unset LXD_IPV6_UPLINK
unset -f ip

legacy_cleanup="$LXD_STATE_DIR/remove_route.sh"
printf '%s\n' '#!/bin/bash' 'ip addr del fe80::1/64 dev eth0' >"$legacy_cleanup"
export LXD_LEGACY_FE80_CLEANUP="$legacy_cleanup"
disable_legacy_link_local_cleanup
[ ! -e "$legacy_cleanup" ] || fail "legacy fe80 cleanup helper was left active"
unset LXD_LEGACY_FE80_CLEANUP

admin_cleanup="$LXD_STATE_DIR/admin-route.sh"
printf '%s\n' '#!/bin/bash' 'ip addr del fe80::2/64 dev eth0' 'echo keep-this-script' >"$admin_cleanup"
export LXD_LEGACY_FE80_CLEANUP="$admin_cleanup"
disable_legacy_link_local_cleanup
[ -e "$admin_cleanup" ] || fail "administrator fe80 script was removed"
unset LXD_LEGACY_FE80_CLEANUP

if grep -Eq 'ip[[:space:]]+addr[[:space:]]+del[[:space:]]+fe80:' "$ROOT_DIR/scripts/build_ipv6_network.sh"; then
    fail "build script still deletes link-local IPv6 addresses"
fi

# Reboot restoration must consume strict prefix metadata and preserve only
# existing global mappings; it must not invent /64 state or bind ULA addresses.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/add-ipv6.sh"
printf '%s\n' 128 >"$LXD_STATE_DIR/lxd_ipv6_mapping_prefix_len"
assert_eq 128 "$(get_host_ipv6_prefixlen eth0)" "strict persisted /128 prefix"
printf '%s\n' 64 128 >"$LXD_STATE_DIR/lxd_ipv6_mapping_prefix_len"
if read_strict_prefix_len "$LXD_STATE_DIR/lxd_ipv6_mapping_prefix_len" >/dev/null; then
    fail "multiline mapping prefix was accepted"
fi
restore_calls="$LXD_STATE_DIR/restore-calls"
# shellcheck disable=SC2329 # Called indirectly by restore_address.
ip() {
    case "$*" in
    "-6 addr show dev eth0") return 1 ;;
    "-6 addr replace "*) printf '%s\n' "$*" >>"$restore_calls" ;;
    *) command ip "$@" ;;
    esac
}
restore_address 'fd42::1' eth0 64
[ ! -s "$restore_calls" ] || fail "ULA was restored as a public address"
restore_address '2606:4700::1' eth0 128
grep -Fq -- '-6 addr replace 2606:4700::1/128 dev eth0' "$restore_calls" || fail "global /128 mapping was not restored"
unset -f ip

printf 'build_ipv6_network tests passed\n'
