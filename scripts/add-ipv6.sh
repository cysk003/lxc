#!/bin/bash
# by https://github.com/oneclickvirt/lxd
# 2026.04.14
# 重启后恢复IPv6地址绑定和防火墙规则

# 获取物理网卡（使用 lshw 原始方式，回退到 sys 扫描）
get_interface() {
    local iface=""
    if command -v lshw >/dev/null 2>&1; then
        iface=$(lshw -C network 2>/dev/null | awk '/logical name:/{print $3}' | head -1)
    fi
    if [ -z "$iface" ]; then
        local iface_path
        for iface_path in /sys/class/net/*; do
            [ -e "$iface_path" ] || continue
            local candidate
            candidate=$(basename "$iface_path")
            [ -e "/sys/devices/virtual/net/$candidate" ] && continue
            iface="$candidate"
            break
        done
    fi
    echo "$iface"
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
    local interface
    interface=$(get_interface)
    if [ -z "$interface" ]; then
        echo "No physical network interface found"
        return 1
    fi
    # 读取存储的前缀长度，回退到64
    local prefix_len=64
    if [ -f /usr/local/bin/lxd_ipv6_prefix_len ]; then
        local stored_len
        stored_len=$(cat /usr/local/bin/lxd_ipv6_prefix_len)
        if [[ "$stored_len" =~ ^[0-9]+$ ]] && [ "$stored_len" -ge 1 ] && [ "$stored_len" -le 128 ]; then
            prefix_len="$stored_len"
        fi
    fi
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
            if ! ip -6 addr show dev "$interface" | grep -q "$parameter"; then
                ip addr add "$parameter"/"$prefix_len" dev "$interface" 2>/dev/null || true
            fi
        done
    fi
    # 恢复ip6tables规则
    if command -v ip6tables-restore >/dev/null 2>&1; then
        ip6tables-restore < "$rules_file" 2>/dev/null
        echo "iptables IPv6 rules restored"
    fi
    # 持久化
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
        netfilter-persistent reload >/dev/null 2>&1
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
    local interface
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
    if [ ${#addrs[@]} -gt 0 ]; then
        # 读取存储的前缀长度，回退到64
        local prefix_len=64
        if [ -f /usr/local/bin/lxd_ipv6_prefix_len ]; then
            local stored_len
            stored_len=$(cat /usr/local/bin/lxd_ipv6_prefix_len)
            if [[ "$stored_len" =~ ^[0-9]+$ ]] && [ "$stored_len" -ge 1 ] && [ "$stored_len" -le 128 ]; then
                prefix_len="$stored_len"
            fi
        fi
        for addr in "${addrs[@]}"; do
            if ! ip -6 addr show dev "$interface" | grep -q "$addr"; then
                ip addr add "$addr"/"$prefix_len" dev "$interface" 2>/dev/null || true
            fi
        done
    fi
    nft -f /etc/nftables.conf 2>/dev/null
    echo "nftables rules restored"
    return 0
}

# 原始iptables方式优先，失败时使用nft补充恢复
if restore_ipt; then
    exit 0
fi
restore_nft
