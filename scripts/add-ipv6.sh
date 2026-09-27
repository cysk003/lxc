#!/bin/bash
# by https://github.com/oneclickvirt/lxd
# 2026.08.26
# 重启后恢复IPv6地址绑定和防火墙规则

STATE_DIR="${LXD_STATE_DIR:-/usr/local/bin}"

valid_interface_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]
}

read_strict_prefix_len() {
    local file="$1" value lines
    [ -f "$file" ] || return 1
    lines=$(awk 'END { print NR + 0 }' "$file" 2>/dev/null) || return 1
    [ "$lines" -eq 1 ] || return 1
    IFS= read -r value <"$file" || [ -n "$value" ] || return 1
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 128 ] || return 1
    printf '%s\n' "$value"
}

get_saved_interface() {
    local saved
    saved=$(cat "$STATE_DIR/lxd_ipv6_mapping_interface" 2>/dev/null || true)
    valid_interface_name "$saved" || return 1
    ip link show dev "$saved" >/dev/null 2>&1 || return 1
    printf '%s\n' "$saved"
}

# Read machine-readable iproute2 output so localized labels cannot affect
# interface or prefix detection. Strip terminal color from wrapped JSON.
restore_ipv6_json_rows() {
    local mode="$1" target="${2:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$mode" "$target" <<'PY'
import ipaddress
import json
import os
import re
import subprocess
import sys

mode, target = sys.argv[1:]
if mode == "default":
    args = ["-6", "route", "show", "default"]
elif mode == "addresses":
    args = ["-6", "addr", "show"]
    if target:
        args += ["dev", target]
else:
    raise SystemExit(1)
try:
    env = dict(os.environ, LC_ALL="C", NO_COLOR="1")
    raw = subprocess.check_output(["ip", "-j", *args], env=env,
                                  stderr=subprocess.DEVNULL)
    data = json.loads(re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", raw))
    if not isinstance(data, list):
        raise ValueError("invalid ip JSON")
    if mode == "default":
        for route in data:
            if route.get("dst", "default") == "default" and route.get("dev"):
                print(route["dev"])
    else:
        for interface in data:
            name = interface.get("ifname", "")
            for item in interface.get("addr_info", []):
                if item.get("family") != "inet6" or item.get("scope") != "global" or item.get("tentative") or "tentative" in item.get("flags", []):
                    continue
                address = ipaddress.IPv6Address(item["local"])
                prefix = int(item["prefixlen"])
                ipaddress.IPv6Interface(f"{address}/{prefix}")
                if address in ipaddress.IPv6Network("2000::/3") and address.is_global:
                    print(name, address.compressed, prefix, sep="\t")
except (OSError, subprocess.CalledProcessError, ValueError, KeyError, TypeError):
    raise SystemExit(1)
PY
}

get_interface() {
    local iface iface_path candidate
    if iface=$(get_saved_interface); then
        printf '%s\n' "$iface"
        return 0
    fi
    iface=$(restore_ipv6_json_rows default 2>/dev/null | head -1)
    if valid_interface_name "$iface" && ip link show dev "$iface" >/dev/null 2>&1; then
        printf '%s\n' "$iface"
        return 0
    fi
    iface=$(restore_ipv6_json_rows addresses 2>/dev/null | awk -F '\t' 'NF == 3 {print $1; exit}')
    if valid_interface_name "$iface" && ip link show dev "$iface" >/dev/null 2>&1; then
        printf '%s\n' "$iface"
        return 0
    fi
    for iface_path in /sys/class/net/*; do
        [ -e "$iface_path" ] || continue
        candidate=$(basename "$iface_path")
        [ -e "/sys/devices/virtual/net/$candidate" ] && continue
        if valid_interface_name "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

get_host_ipv6_prefixlen() {
    local iface="$1" plen
    plen=$(read_strict_prefix_len "$STATE_DIR/lxd_ipv6_mapping_prefix_len" 2>/dev/null || true)
    if [ -n "$plen" ]; then
        printf '%s\n' "$plen"
        return 0
    fi
    plen=$(restore_ipv6_json_rows addresses "$iface" 2>/dev/null | awk -F '\t' 'NF == 3 {print $3; exit}')
    [[ "$plen" =~ ^[0-9]+$ ]] && [ "$plen" -ge 1 ] && [ "$plen" -le 128 ] || return 1
    printf '%s\n' "$plen"
}

is_restorable_global_ipv6() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${1:-}" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address in ipaddress.IPv6Network("2000::/3") and address.is_global else 1)
PY
}

normalize_restorable_global_ipv6() {
    python3 - "${1:-}" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
if address not in ipaddress.IPv6Network("2000::/3") or not address.is_global:
    raise SystemExit(1)
print(address.compressed)
PY
}

restore_address() {
    local address="$1" interface="$2" prefix_len="$3" rows
    [[ "$prefix_len" =~ ^[0-9]+$ ]] && [ "$prefix_len" -ge 1 ] && [ "$prefix_len" -le 128 ] || return 1
    address=$(normalize_restorable_global_ipv6 "$address" 2>/dev/null) || return 0
    rows=$(restore_ipv6_json_rows addresses "$interface") || return 1
    if ! printf '%s\n' "$rows" | awk -F '\t' -v addr="$address" '$2 == addr {found=1} END {exit !found}'; then
        # A mapped address is a host alias, not another connected prefix.
        ip -6 addr replace "$address/128" dev "$interface" 2>/dev/null || return 1
    fi
}

extract_nft_daddr() {
    sed -nE 's/.*ip6[[:space:]]+daddr[[:space:]]+([0-9A-Fa-f:]+).*/\1/p' /etc/nftables.conf | sort -u
}

# 恢复iptables规则（原始方式，优先）
restore_ipt() {
    local rules_file="/etc/iptables/rules.v6"
    if [ ! -f "$rules_file" ] || [ ! -s "$rules_file" ]; then
        return 1
    fi
    # 检查文件中是否有有效的 PREROUTING 规则
    if ! grep -q "^\-A PREROUTING \-d" "$rules_file" 2>/dev/null; then
        return 1
    fi
    local interface prefix_len
    interface=$(get_interface)
    [ -n "$interface" ] || return 1
    prefix_len=$(get_host_ipv6_prefixlen "$interface" 2>/dev/null || true)
    [ -n "$prefix_len" ] || return 1
    [ "$(cat "$STATE_DIR/lxd_ipv6_mode" 2>/dev/null || true)" = "nat66" ] && return 0
    # 从规则文件中提取需要绑定到接口的IPv6地址（原始逻辑）
    local array=()
    while IFS= read -r line; do
        if [[ $line == "-A PREROUTING -d"* ]]; then
            parameter="${line#*-d }"
            parameter="${parameter%%/*}"
            array+=("$parameter")
        fi
    done < "$rules_file"
    if [ ${#array[@]} -gt 0 ]; then
        for parameter in "${array[@]}"; do
            restore_address "$parameter" "$interface" "$prefix_len" || return 1
        done
    fi
    # 恢复ip6tables规则
    if command -v ip6tables-restore >/dev/null 2>&1; then
        ip6tables-restore < "$rules_file" 2>/dev/null || return 1
        echo "iptables IPv6 rules restored"
    fi
    # 持久化
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || return 1
        netfilter-persistent reload >/dev/null 2>&1 || return 1
    fi
    return 0
}

# 恢复nftables规则（新方式，作为补充）
restore_nft() {
    if ! command -v nft >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -f /etc/nftables.conf ] || [ ! -s /etc/nftables.conf ]; then
        return 1
    fi
    # 检查配置中是否有IPv6 DNAT规则
    if ! grep -q "ip6 daddr" /etc/nftables.conf 2>/dev/null; then
        return 1
    fi
    local interface prefix_len
    interface=$(get_interface)
    if [ -z "$interface" ]; then
        echo "No physical network interface found"
        return 1
    fi
    # 从nftables配置中提取 ip6 daddr（公网IPv6，需绑定到接口）
    local addrs=()
    while IFS= read -r addr; do
        [ -n "$addr" ] && addrs+=("$addr")
    done < <(extract_nft_daddr)
    prefix_len=$(get_host_ipv6_prefixlen "$interface" 2>/dev/null || true)
    [ -n "$prefix_len" ] || return 1
    [ "$(cat "$STATE_DIR/lxd_ipv6_mode" 2>/dev/null || true)" = "nat66" ] && return 0
    if [ ${#addrs[@]} -gt 0 ]; then
        for addr in "${addrs[@]}"; do
            restore_address "$addr" "$interface" "$prefix_len" || return 1
        done
    fi
    nft -f /etc/nftables.conf 2>/dev/null || return 1
    echo "nftables rules restored"
    return 0
}

# 原始iptables方式优先，失败时使用nft补充恢复
main() {
    if restore_ipt; then
        return 0
    fi
    restore_nft
}

if [ "${ONECLICKVIRT_TESTING:-0}" != "1" ]; then
    main "$@"
fi
