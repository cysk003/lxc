#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/lxd-ipv6-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$tmpdir/bin" "$tmpdir/state"
cat >"$tmpdir/bin/ip" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    '-j -6 addr show')
        if [[ "${LXD_TEST_DELEGATED:-}" == 1 ]]; then
            printf '\033[36m%s\033[0m\n' '[{"ifname":"vmbr0","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":128,"scope":"global"}]},{"ifname":"vmbr2","addr_info":[{"family":"inet6","local":"2a14:7c0:1002:10f8::1","prefixlen":38,"scope":"global"}]}]'
        elif [[ "${LXD_TEST_NO_LOCAL_IPV6:-}" == 1 ]]; then
            printf '%s\n' '[{"ifname":"eth0","addr_info":[]}]'
        elif [[ "${LXD_TEST_LOCAL_ULA_FIRST:-}" == 1 ]]; then
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"fd42::1","prefixlen":64,"scope":"global"},{"family":"inet6","local":"2606:4700::1111","prefixlen":64,"scope":"global"}]}]'
        else
            printf '%s\n' '[{"ifname":"eth0","addr_info":[{"family":"inet6","local":"2606:4700::1111","prefixlen":64,"scope":"global"}]}]'
        fi
        ;;
    '-j -6 route show default') printf '%s\n' '[]' ;;
    *) exit 2 ;;
esac
STUB
cat >"$tmpdir/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'external IPv6 lookup invoked\n' >"${LXD_TEST_CURL_MARKER:?}"
exit 1
STUB
chmod 700 "$tmpdir/bin/ip" "$tmpdir/bin/curl"

export PATH="$tmpdir/bin:$PATH"
export LXD_STATE_DIR="$tmpdir/state"
export LXD_TEST_CURL_MARKER="$tmpdir/curl-called"
export LXD_TEST_LOCAL_ULA_FIRST=1
export ONECLICKVIRT_TESTING=1
# shellcheck disable=SC1091 # The test sources the repository script through a computed path.
source "$repo_root/scripts/build_ipv6_network.sh"

detected=$(check_ipv6)
[[ "$detected" == "2606:4700::1111" ]] || fail "local IPv6 = '$detected'"
[[ "$(cat "$tmpdir/state/lxd_check_ipv6")" == "2606:4700::1111" ]] || fail "local IPv6 was not persisted"
[[ ! -e "$LXD_TEST_CURL_MARKER" ]] || fail "check_ipv6 used an external address service"
unset LXD_TEST_LOCAL_ULA_FIRST
if is_private_ipv6 "2606:4700::1111"; then
    fail "a public 2606 IPv6 address was classified as private"
fi
if ! is_private_ipv6 "2001::"; then
    fail "the compressed Teredo prefix was accepted as public"
fi
if ! is_private_ipv6 "fc12::1" || ! is_private_ipv6 "fe90::1" || ! is_private_ipv6 "fec0::1" || ! is_private_ipv6 "ff02::1" || ! is_private_ipv6 "2001:0000::1" || ! is_private_ipv6 "2001:0010::1"; then
    fail "local, site-local, or multicast IPv6 was accepted as public"
fi

export LXD_TEST_NO_LOCAL_IPV6=1
if check_ipv6 >/dev/null 2>&1; then
    fail "check_ipv6 accepted a host without a locally bound public IPv6 address"
fi
[[ ! -e "$LXD_TEST_CURL_MARKER" ]] || fail "missing local IPv6 triggered an external lookup"

# The same address can be a host-only /128 on the uplink and a delegated /38
# on a direct bridge. Retain the bridge, not the first matching /128.
# shellcheck disable=SC2329 # Called indirectly by the sourced network helpers.
ip() {
    case "$*" in
        "-o -6 addr show scope global")
            printf '%s\n' \
                '3: vmbr0    inet6 2a14:7c0:1002:10f8::1/128 scope global' \
                '5: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
            ;;
        "-o -6 addr show dev vmbr2 scope global")
            printf '%s\n' '5: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
            ;;
        *)
            command ip "$@"
            ;;
    esac
}
export LXD_TEST_DELEGATED=1
check_ipv6 >/dev/null || fail "delegated /38 was not accepted"
[[ "$IPV6" == "2a14:7c0:1002:10f8::1" ]] || fail "delegated /38 selection = '$IPV6'"
[[ "$(ipv6_uplink_interface "$IPV6")" == "vmbr2" ]] || fail "delegated /38 interface was not selected"
unset LXD_TEST_DELEGATED
unset -f ip
unset LXD_TEST_NO_LOCAL_IPV6

# shellcheck disable=SC2016 # The literal is the source-code contract under test.
if ! grep -Fq 'net.ipv6.conf.${ipv6_network_name}.accept_ra=2' "$repo_root/scripts/build_ipv6_network.sh"; then
    fail "IPv6 forwarding must preserve router advertisements on the LXD uplink"
fi
# shellcheck disable=SC2016 # The literal is the source-code contract under test.
if ! grep -Fq 'net.ipv6.conf.all.proxy_ndp=1' "$repo_root/scripts/build_ipv6_network.sh"; then
    fail "LXD routed NICs require global NDP proxying"
fi
if ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$repo_root/scripts/build_ipv6_network.sh" ||
   ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$repo_root/scripts/buildct.sh" ||
   ! grep -Fq -- '-6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb' "$repo_root/scripts/buildvm.sh"; then
    fail "IPv6 keepalive jobs must force IPv6 and fail closed on probe errors"
fi

printf 'LXD IPv6 local-address tests passed\n'
