#!/bin/bash
# by https://github.com/oneclickvirt/lxd
# 2026.08.26

# ./build_ipv6_network.sh LXC容器名称 <是否使用nft/ipt进行映射>

LXD_STATE_DIR="${LXD_STATE_DIR:-/usr/local/bin}"

state_file() {
    printf '%s/%s\n' "${LXD_STATE_DIR%/}" "$1"
}

has_unsafe_scalar_chars() {
    local value="$1"
    [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\033'* ]]
}

normalize_ipv6_address() {
    local value="$1"
    ! has_unsafe_scalar_chars "$value" || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1].strip().strip("[]"))
except ValueError:
    raise SystemExit(1)
if address.version != 6:
    raise SystemExit(1)
print(address.compressed)
PY
}

normalize_ipv6_interface() {
    local value="$1"
    ! has_unsafe_scalar_chars "$value" || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    interface = ipaddress.ip_interface(sys.argv[1].strip())
except ValueError:
    raise SystemExit(1)
if interface.version != 6:
    raise SystemExit(1)
print(interface.with_prefixlen)
PY
}

normalize_ipv6_network() {
    local value="$1"
    ! has_unsafe_scalar_chars "$value" || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_interface(sys.argv[1].strip()).network
except ValueError:
    raise SystemExit(1)
if network.version != 6:
    raise SystemExit(1)
print(network.with_prefixlen)
PY
}

write_atomic_scalar() {
    local file="$1" value="$2" dir tmp
    [ -n "$value" ] && ! has_unsafe_scalar_chars "$value" || return 1
    dir=${file%/*}
    [ "$dir" != "$file" ] || dir=.
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$value" >"$tmp" || ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}

read_strict_ipv6_file() {
    local file="$1" value line_count
    [ -f "$file" ] || return 1
    line_count=$(awk 'END { print NR + 0 }' "$file" 2>/dev/null) || return 1
    [ "$line_count" -eq 1 ] || return 1
    IFS= read -r value <"$file" || [ -n "$value" ] || return 1
    normalize_ipv6_address "$value"
}

select_ipv6_interface() {
    local preferred_address="${1:-}" candidates="${2:-}"
    ! has_unsafe_scalar_chars "$preferred_address" || return 1
    python3 - "$preferred_address" "$candidates" <<'PY'
import ipaddress
import sys

preferred = sys.argv[1].strip()
values = []
for raw in sys.argv[2].splitlines():
    try:
        interface = ipaddress.ip_interface(raw.strip())
    except ValueError:
        continue
    if interface.version != 6:
        continue
    if preferred and interface.ip.compressed == preferred:
        print(interface.with_prefixlen)
        raise SystemExit(0)
    values.append(interface)
if values:
    print(values[0].with_prefixlen)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

random_ipv6_candidate() {
    local network="$1" excluded="${2:-}"
    python3 - "$network" "$excluded" <<'PY'
import ipaddress
import secrets
import sys

try:
    network = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
    excluded = ipaddress.ip_address(sys.argv[2]) if sys.argv[2] else None
except ValueError:
    raise SystemExit(1)
if network.version != 6:
    raise SystemExit(1)
available = network.num_addresses - (1 if excluded in network else 0)
if available < 1:
    raise SystemExit(1)
for _ in range(256):
    candidate = ipaddress.ip_address(int(network.network_address) + secrets.randbelow(network.num_addresses))
    if candidate != excluded:
        print(candidate.compressed)
        raise SystemExit(0)
for candidate in network:
    if candidate != excluded:
        print(candidate.compressed)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

generate_ipv6_candidates() {
    local network="$1" limit="${2:-65533}"
    python3 - "$network" "$limit" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
    limit = int(sys.argv[2])
except (ValueError, IndexError):
    raise SystemExit(1)
if network.version != 6 or limit < 1:
    raise SystemExit(1)
for offset in range(min(limit, network.num_addresses)):
    print(ipaddress.ip_address(int(network.network_address) + offset).compressed)
PY
}

get_container_ipv6() {
    local container_name="$1" value
    value=$(lxc list "$container_name" --format=json | jq -er '
        [.[0].state.network.eth0.addresses[]? | select(.family == "inet6" and .scope == "global") | .address]
        | unique
        | if length == 1 then .[0] else error("expected exactly one global IPv6 address") end
    ') || return 1
    normalize_ipv6_address "$value"
}

get_host_ipv6_interface() {
    local raw
    raw=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}')
    select_ipv6_interface "" "$raw"
}

# 检测防火墙后端：优先nftables，回退iptables
detect_firewall_backend() {
    FW_BACKEND=""
    if command -v nft >/dev/null 2>&1; then
        FW_BACKEND="nft"
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y nftables >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y nftables >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y nftables >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm nftables >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache nftables >/dev/null 2>&1
    fi
    if command -v nft >/dev/null 2>&1; then
        FW_BACKEND="nft"
        return 0
    fi
    FW_BACKEND="ipt"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1
    fi
    return 0
}

save_firewall_rules() {
    if [ "$FW_BACKEND" = "nft" ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables >/dev/null 2>&1
        fi
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        fi
    fi
}

# 服务管理兼容性函数
service_manager() {
    local action=$1
    local service_name=$2
    local success=false
    
    case "$action" in
        daemon-reload)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload 2>/dev/null && success=true
            else
                success=true
            fi
            ;;
        enable)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable "$service_name" 2>/dev/null && success=true
            fi
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add "$service_name" default 2>/dev/null && success=true
            fi
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d "$service_name" defaults 2>/dev/null && success=true
            fi
            ;;
        start)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl start "$service_name" 2>/dev/null && success=true
            fi
            if ! $success && command -v rc-service >/dev/null 2>&1; then
                rc-service "$service_name" start 2>/dev/null && success=true
            fi
            if ! $success && command -v service >/dev/null 2>&1; then
                service "$service_name" start 2>/dev/null && success=true
            fi
            if ! $success && [ -x "/etc/init.d/$service_name" ]; then
                /etc/init.d/"$service_name" start 2>/dev/null && success=true
            fi
            ;;
    esac
    
    $success && return 0 || return 1
}

# 输出颜色函数
_red() { printf '\033[31m\033[01m%s\033[0m\n' "$*"; }
_green() { printf '\033[32m\033[01m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[33m\033[01m%s\033[0m\n' "$*"; }
_blue() { printf '\033[36m\033[01m%s\033[0m\n' "$*"; }

# 设置UTF-8环境
setup_locale() {
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
    if [[ -z "$utf8_locale" ]]; then
        _yellow "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        _green "Locale set to $utf8_locale"
    fi
}

# 安装依赖包
install_package() {
    package_name=$1
    if command -v "$package_name" >/dev/null 2>&1; then
        _green "$package_name has been installed"
        _green "$package_name 已经安装"
    else
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name"; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name" --fix-missing
        fi
        _green "$package_name has attempted to install"
        _green "$package_name 已尝试安装"
    fi
}

append_cron_once() {
    local cron_line=$1
    if ! crontab -l 2>/dev/null | grep -Fqx "$cron_line"; then
        (crontab -l 2>/dev/null; printf '%s\n' "$cron_line") | crontab -
    fi
}

get_physical_interface() {
    local iface=""
    if command -v lshw >/dev/null 2>&1; then
        iface=$(lshw -C network 2>/dev/null | awk '/logical name:/{print $3}' | head -n 1)
    fi
    if [ -z "$iface" ]; then
        local iface_path candidate
        for iface_path in /sys/class/net/*; do
            [ -e "$iface_path" ] || continue
            candidate=$(basename "$iface_path")
            [ -e "/sys/devices/virtual/net/$candidate" ] && continue
            iface="$candidate"
            break
        done
    fi
    printf '%s\n' "$iface"
}

# Resolve the interface that owns the selected global IPv6 address. This keeps
# HE/6in4, sit/vti/GRE and routed-bridge deployments on their actual tunnel or
# bridge instead of guessing the first physical NIC.
ipv6_uplink_interface() {
    local preferred="${1:-}" requested="${LXD_IPV6_UPLINK:-}" iface fallback_iface raw cidr normalized network
    if [ -n "$requested" ] && [[ "$requested" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
        if [ -z "$preferred" ] || ip -o -6 addr show dev "$requested" scope global 2>/dev/null | grep -q .; then
            printf '%s\n' "$requested"
            return 0
        fi
    fi
    if [ -n "$preferred" ]; then
        # A host /128 and a delegated bridge can carry the same address. Keep
        # the bridge whose CIDR can still supply a guest address.
        while read -r iface cidr; do
            [ -n "$iface" ] && [ -n "$cidr" ] || continue
            raw=${cidr%/*}
            normalized=$(normalize_ipv6_address "$raw" 2>/dev/null || true)
            [ "$normalized" = "$preferred" ] || continue
            fallback_iface="${fallback_iface:-$iface}"
            network=$(ipv6_allocation_network "$cidr" 2>/dev/null || true)
            if [ -n "$network" ] && ipv6_pool_has_extra_address "$network" "$normalized"; then
                printf '%s\n' "$iface"
                return 0
            fi
        done < <(ip -o -6 addr show scope global 2>/dev/null | awk '$4 ~ /^[^ ]+\/[0-9]+$/ {print $2, $4}')
        [ -n "$fallback_iface" ] && { printf '%s\n' "$fallback_iface"; return 0; }
    fi
    iface=$(ip -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    if [ -n "$iface" ] && ip -o -6 addr show dev "$iface" scope global 2>/dev/null | grep -q .; then
        printf '%s\n' "$iface"
        return 0
    fi
    while IFS= read -r iface; do
        case "$iface" in
        he-ipv6 | sit* | ip6tnl* | 6in4* | vti* | gre*)
            if ip -o -6 addr show dev "$iface" scope global 2>/dev/null | grep -q .; then
                printf '%s\n' "$iface"
                return 0
            fi
            ;;
        esac
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
    iface=$(get_physical_interface)
    [ -n "$iface" ] || return 1
    printf '%s\n' "$iface"
}

ipv6_uplink_cidr() {
    local iface="$1" preferred="${2:-}" raw
    [ -n "$iface" ] || return 1
    raw=$(ip -o -6 addr show dev "$iface" scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}')
    select_ipv6_interface "$preferred" "$raw"
}

# A /128 host route cannot be treated as a public address pool. A routed /64,
# /38 or /127 remains usable when the upstream provides routing/NDP support.
ipv6_allocation_network() {
    local detected="${1:-}" requested="${LXD_IPV6_ROUTED_PREFIX:-}" value
    value="${requested:-$detected}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$value" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
except ValueError:
    raise SystemExit(1)
if network.version != 6 or network.prefixlen > 127:
    raise SystemExit(1)
if not network.subnet_of(ipaddress.IPv6Network("2000::/3")):
    raise SystemExit(1)
print(network.with_prefixlen)
PY
}

ipv6_pool_has_extra_address() {
    local network="$1" excluded="${2:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$network" "$excluded" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1].strip(), strict=False)
    excluded = ipaddress.IPv6Address(sys.argv[2]) if sys.argv[2] else None
except ValueError:
    raise SystemExit(1)
if network.prefixlen > 127:
    raise SystemExit(1)
available = network.num_addresses - (1 if excluded is not None and excluded in network else 0)
raise SystemExit(0 if available > 0 else 1)
PY
}

disable_legacy_link_local_cleanup() {
    local legacy="${LXD_LEGACY_FE80_CLEANUP:-/usr/local/bin/remove_route.sh}" current
    [ -f "$legacy" ] || return 0
    # Remove only the minimal legacy helper generated by this project. A
    # user-maintained script that happens to mention fe80 must be preserved.
    awk '
        BEGIN { commands = 0; valid = 1 }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        /^[[:space:]]*ip([[:space:]]+-6)?[[:space:]]+addr[[:space:]]+del[[:space:]]+fe80:[0-9A-Fa-f:]+(\/[0-9]+)?[[:space:]]+dev[[:space:]]+[A-Za-z0-9_.:-]+[[:space:]]*$/ { commands++; next }
        { valid = 0 }
        END { exit !(valid && commands == 1) }
    ' "$legacy" || return 0
    if command -v crontab >/dev/null 2>&1; then
        current=$(crontab -l 2>/dev/null || true)
        if printf '%s\n' "$current" | grep -Fq "$legacy"; then
            printf '%s\n' "$current" |
                awk -v path="$legacy" '{ line = $0; sub(/^[[:space:]]*@reboot[[:space:]]+/, "", line); if (line != path) print }' |
                crontab - 2>/dev/null || true
        fi
    fi
    rm -f -- "$legacy"
}

configure_ipv6_nat66_fallback() {
    local network="${LXD_IPV6_NETWORK:-lxdbr0}" parent current existing_mode
    if command -v lxc >/dev/null 2>&1 && [ -n "${CONTAINER_NAME:-}" ]; then
        parent=$(lxc config device get "$CONTAINER_NAME" eth0 parent 2>/dev/null || true)
        [[ "$parent" =~ ^[A-Za-z0-9_.:-]+$ ]] && network="$parent"
        current=$(lxc network get "$network" ipv6.address 2>/dev/null || true)
        if [ -z "$current" ] || [ "$current" = "none" ]; then
            lxc network set "$network" ipv6.address auto 2>/dev/null || true
        fi
        lxc network set "$network" ipv6.nat true 2>/dev/null || true
    fi
    existing_mode=$(cat "$(state_file lxd_ipv6_mode)" 2>/dev/null || true)
    if [ "$existing_mode" != routed ] && [ "$existing_mode" != public-nat ] &&
        [ ! -s "$(state_file lxd_ipv6_mapping_interface)" ]; then
        write_atomic_scalar "$(state_file lxd_ipv6_mode)" nat66 2>/dev/null || true
    fi
    _yellow "No additional routed IPv6 address is available; retaining the container IPv6 network and enabling NAT66 where supported."
    _yellow "宿主机没有可分配的额外公网 IPv6；保留容器 IPv6 网络，并在支持时启用 NAT66。"
}

# Check whether an IPv6 address is a usable GUA allocation source. Textual
# prefix tests are unsafe because the same address may contain leading zeros.
is_public_ipv6() {
    local address="${1:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$address" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),       # Teredo
    ipaddress.IPv6Network("2001:2::/48"),     # benchmarking
    ipaddress.IPv6Network("2001:10::/28"),    # ORCHID
    ipaddress.IPv6Network("2001:20::/28"),    # ORCHIDv2
    ipaddress.IPv6Network("2001:db8::/32"),   # documentation
    ipaddress.IPv6Network("2002::/16"),       # 6to4
    ipaddress.IPv6Network("3fff::/20"),       # documentation
)
usable = (
    address in global_unicast
    and address.is_global
    and not address.is_private
    and not address.is_multicast
    and not any(address in prefix for prefix in non_public)
)
raise SystemExit(0 if usable else 1)
PY
}

# 检查IPv6地址是否为私有地址
is_private_ipv6() {
    ! is_public_ipv6 "${1:-}"
}

# 获取公网IPv6地址
check_ipv6() {
    local candidate state_path normalized prefix fallback network
    state_path=$(state_file lxd_check_ipv6)
    IPV6=""
    fallback=""
    while IFS= read -r candidate; do
        prefix="${candidate##*/}"
        candidate=${candidate%/*}
        if normalized=$(normalize_ipv6_address "$candidate" 2>/dev/null) && ! is_private_ipv6 "$normalized"; then
            fallback="${fallback:-$normalized}"
            if network=$(ipv6_allocation_network "${normalized}/${prefix}" 2>/dev/null) &&
                ipv6_pool_has_extra_address "$network" "$normalized"; then
                IPV6="$normalized"
                break
            fi
        fi
    done < <(ip -o -6 addr show scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}')
    [ -n "$IPV6" ] || IPV6="$fallback"
    [ -n "$IPV6" ] || return 1
    write_atomic_scalar "$state_path" "$IPV6"
    printf '%s\n' "$IPV6"
}

# 更新系统配置参数
update_sysctl() {
    sysctl_config="$1"  # 格式: key=value
    key="${sysctl_config%%=*}"
    value="${sysctl_config#*=}"
    # 目标配置文件（systemd 方式）
    custom_conf="/etc/sysctl.d/99-custom.conf"
    mkdir -p /etc/sysctl.d
    # 检查 /etc/sysctl.conf 是否存在并且在系统加载路径中
    use_etc_sysctl_conf=false
    if [ -f /etc/sysctl.conf ]; then
        if grep -q "/etc/sysctl.conf" /etc/sysctl.d/README* 2>/dev/null || \
           grep -q "/etc/sysctl.conf" /lib/systemd/system/sysctl.service 2>/dev/null; then
            use_etc_sysctl_conf=true
        fi
    fi
    # 更新 /etc/sysctl.d/99-custom.conf
    if grep -q "^$sysctl_config" "$custom_conf" 2>/dev/null; then
        : # 已经有正确配置，跳过
    elif grep -q "^#$sysctl_config" "$custom_conf" 2>/dev/null; then
        sed -i "s/^#$sysctl_config/$sysctl_config/" "$custom_conf"
    elif grep -q "^$key" "$custom_conf" 2>/dev/null; then
        sed -i "s|^$key.*|$sysctl_config|" "$custom_conf"
    else
        echo "$sysctl_config" >> "$custom_conf"
    fi
    # 如果系统还在用 /etc/sysctl.conf，也同步更新
    if [ "$use_etc_sysctl_conf" = true ]; then
        if grep -q "^$sysctl_config" /etc/sysctl.conf; then
            : # 已经有正确配置
        elif grep -q "^#$sysctl_config" /etc/sysctl.conf; then
            sed -i "s/^#$sysctl_config/$sysctl_config/" /etc/sysctl.conf
        elif grep -q "^$key" /etc/sysctl.conf; then
            sed -i "s|^$key.*|$sysctl_config|" /etc/sysctl.conf
        else
            echo "$sysctl_config" >> /etc/sysctl.conf
        fi
    fi
    sysctl -w "$key=$value" >/dev/null 2>&1
}

# 等待容器状态变更
wait_for_container_status() {
    container_name=$1
    target_status=$2
    timeout=$3
    interval=3
    elapsed_time=0
    while [ "$elapsed_time" -lt "$timeout" ]; do
        status=$(lxc info "$container_name" | grep "Status: $target_status")
        if [[ "$status" == *"$target_status"* ]]; then
            return 0
        fi
        echo "Waiting for the container \"$container_name\" to $target_status..."
        echo "${status}"
        sleep $interval
        elapsed_time=$((elapsed_time + interval))
    done
    return 1
}

# 使用网络设备方式映射IPv6
setup_network_device_mapping() {
    local ipv6_state raw_interfaces host_address allocation_cidr
    ipv6_state=$(state_file lxd_check_ipv6)
    IPV6=$(read_strict_ipv6_file "$ipv6_state" 2>/dev/null || true)
    if [ -z "$IPV6" ]; then
        IPV6=$(check_ipv6) || return 1
    fi
    ipv6_network_name=$(ipv6_uplink_interface "$IPV6" 2>/dev/null || true)
    raw_interfaces=$(ip -o -6 addr show dev "$ipv6_network_name" scope global 2>/dev/null | awk '{print $4}')
    ip_network_gam=$(select_ipv6_interface "$IPV6" "$raw_interfaces" 2>/dev/null || true)
    _yellow "Local IPV6 address: $ip_network_gam"
    if [ -n "$ip_network_gam" ]; then
        # Linux suppresses ordinary router advertisements after forwarding is
        # enabled unless the uplink explicitly opts in. Keep SLAAC routes.
        update_sysctl "net.ipv6.conf.${ipv6_network_name}.accept_ra=2"
        update_sysctl "net.ipv6.conf.${ipv6_network_name}.proxy_ndp=1"
        update_sysctl "net.ipv6.conf.all.forwarding=1"
        update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
        sysctl_path=$(which sysctl)
        ${sysctl_path} -p
        allocation_cidr=$(ipv6_allocation_network "$ip_network_gam" 2>/dev/null || true)
        host_address=${ip_network_gam%/*}
        if [ -z "$allocation_cidr" ] || ! ipv6_pool_has_extra_address "$allocation_cidr" "$host_address"; then
            _red "No additional IPv6 address is available in $ip_network_gam"
            _red "宿主机前缀没有可分配的额外 IPv6 地址（/128 不是地址池）"
            configure_ipv6_nat66_fallback
            return 0
        fi
        lxc_ipv6=$(random_ipv6_candidate "$allocation_cidr" "$host_address") || {
            _red "No additional IPv6 address is available in $allocation_cidr"
            configure_ipv6_nat66_fallback
            return 0
        }
        _green "Container $CONTAINER_NAME IPV6:"
        _green "$lxc_ipv6"
        lxc stop "$CONTAINER_NAME"
        sleep 3
        wait_for_container_status "$CONTAINER_NAME" "STOPPED" 24
        lxc config device remove "$CONTAINER_NAME" eth1 2>/dev/null || true
        if ! lxc config device add "$CONTAINER_NAME" eth1 nic nictype=routed parent="$ipv6_network_name" ipv6.address="$lxc_ipv6"; then
            _red "Failed to add routed IPv6 device for $CONTAINER_NAME"
            _red "为 $CONTAINER_NAME 添加 routed IPv6 设备失败"
            return 1
        fi
        sleep 3
        lxc start "$CONTAINER_NAME"
        handle_fe80_gateway "$ipv6_gateway_fe80" "$ipv6_network_name"
        setup_ipv6_cron
        write_atomic_scalar "${CONTAINER_NAME}_v6" "$lxc_ipv6"
        write_atomic_scalar "$(state_file lxd_ipv6_mode)" routed || true
    else
        _red "No host IPv6 network address found for routed mapping"
        _red "未找到宿主机 IPv6 网络地址，无法使用 routed 方式映射"
        return 1
    fi
}

# 处理fe80网关
handle_fe80_gateway() {
    local gateway_kind="${1:-N}" interface="${2:-}"
    disable_legacy_link_local_cleanup
    if [[ "$gateway_kind" == "Y" ]]; then
        _blue "Retaining the link-local IPv6 gateway on ${interface:-the uplink}; it is required for RA/NDP."
    else
        _blue "Retaining link-local IPv6 addresses on ${interface:-the uplink}; no destructive cleanup is performed."
    fi
}

# 设置IPv6相关的定时任务
setup_ipv6_cron() {
    append_cron_once '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb'
}

# 使用nft/ipt映射IPv6
setup_firewall_mapping() {
    if ! IPV6_NETWORK=$(ipv6_allocation_network "${IPV6_NETWORK:-}" 2>/dev/null) ||
        ! ipv6_pool_has_extra_address "$IPV6_NETWORK" "${IPV6:-}"; then
        configure_ipv6_nat66_fallback
        return 0
    fi
    detect_firewall_backend
    if [ "$FW_BACKEND" = "nft" ]; then
        setup_nft_mapping
    else
        install_package netfilter-persistent
        setup_ipt_mapping
    fi
}

# 使用nftables映射IPv6
setup_nft_mapping() {
    local found_ipv6=""
    while IFS= read -r IPV6; do
        if [[ $IPV6 == "$CONTAINER_IPV6" ]]; then
            continue
        fi
        if ip -6 addr show dev "$interface" | grep -q "$IPV6"; then
            continue
        fi
        if ! ping6 -c1 -w1 -q "$IPV6" &>/dev/null; then
            if ! nft list ruleset 2>/dev/null | grep -F "ip6 daddr $IPV6" | grep -Fq "dnat to $CONTAINER_IPV6"; then
                _green "$IPV6"
                found_ipv6="$IPV6"
                break
            fi
        fi
        _yellow "$IPV6"
    done < <(generate_ipv6_candidates "$IPV6_NETWORK" 65533)
    if [ -z "$found_ipv6" ]; then
        _red "No IPV6 address available, no auto mapping"
        _red "无可用 IPV6 地址，不进行自动映射"
        exit 1
    fi
    IPV6="$found_ipv6"
    write_atomic_scalar "$(state_file lxd_ipv6_mapping_interface)" "$interface" || return 1
    write_atomic_scalar "$(state_file lxd_ipv6_mapping_prefix_len)" "$ipv6_length" || return 1
    write_atomic_scalar "$(state_file lxd_ipv6_mode)" public-nat || return 1
    ip addr add "$IPV6"/"$ipv6_length" dev "$interface"
    # 创建nftables IPv6 NAT表
    nft list table ip6 lxd_ipv6_nat >/dev/null 2>&1 || nft add table ip6 lxd_ipv6_nat
    nft list chain ip6 lxd_ipv6_nat prerouting >/dev/null 2>&1 || \
        nft 'add chain ip6 lxd_ipv6_nat prerouting { type nat hook prerouting priority -100; policy accept; }'
    nft list chain ip6 lxd_ipv6_nat postrouting >/dev/null 2>&1 || \
        nft 'add chain ip6 lxd_ipv6_nat postrouting { type nat hook postrouting priority 100; policy accept; }'
    nft add rule ip6 lxd_ipv6_nat prerouting ip6 daddr "$IPV6" dnat to "$CONTAINER_IPV6"
    nft add rule ip6 lxd_ipv6_nat postrouting ip6 saddr "$CONTAINER_IPV6" snat to "$IPV6"
    # 持久化
    setup_persistence_service
    save_firewall_rules
    test_ipv6_connectivity "$IPV6"
    write_atomic_scalar "${CONTAINER_NAME}_v6" "$IPV6"
}

# 使用iptables映射IPv6
setup_ipt_mapping() {
    # 寻找未使用的子网内的一个IPV6地址
    local found_ipv6=""
    while IFS= read -r IPV6; do
        if [[ $IPV6 == "$CONTAINER_IPV6" ]]; then
            continue
        fi
        if ip -6 addr show dev "$interface" | grep -q "$IPV6"; then
            continue
        fi
        if ! ping6 -c1 -w1 -q "$IPV6" &>/dev/null; then
            if ! ip6tables -t nat -C PREROUTING -d "$IPV6" -j DNAT --to-destination "$CONTAINER_IPV6" &>/dev/null; then
                _green "$IPV6"
                found_ipv6="$IPV6"
                break
            fi
        fi
        _yellow "$IPV6"
    done < <(generate_ipv6_candidates "$IPV6_NETWORK" 65533)
    # 检查是否找到未使用的 IPV6 地址
    if [ -z "$found_ipv6" ]; then
        _red "No IPV6 address available, no auto mapping"
        _red "无可用 IPV6 地址，不进行自动映射"
        exit 1
    fi
    IPV6="$found_ipv6"
    write_atomic_scalar "$(state_file lxd_ipv6_mapping_interface)" "$interface" || return 1
    write_atomic_scalar "$(state_file lxd_ipv6_mapping_prefix_len)" "$ipv6_length" || return 1
    write_atomic_scalar "$(state_file lxd_ipv6_mode)" public-nat || return 1
    # 映射 IPV6 地址到容器的私有 IPV6 地址
    ip addr add "$IPV6"/"$ipv6_length" dev "$interface"
    ip6tables -t nat -A PREROUTING -d "$IPV6" -j DNAT --to-destination "$CONTAINER_IPV6"
    ip6tables -t nat -A POSTROUTING -s "$CONTAINER_IPV6" -j SNAT --to-source "$IPV6"
    # 设置持久化服务
    setup_persistence_service
    # 保存iptables规则
    save_firewall_rules
    # 测试连通性
    test_ipv6_connectivity "$IPV6"
    # 写入信息
    write_atomic_scalar "${CONTAINER_NAME}_v6" "$IPV6"
}

# 检测CDN
check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=()
    mapfile -t shuffled_cdn_urls < <(printf '%s\n' "${cdn_urls[@]}" | shuf)
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

# 检测CDN可用性
check_cdn_file() {
    local withoutcdn_upper
    withoutcdn_upper=$(printf '%s' "${WITHOUTCDN:-}" | tr '[:lower:]' '[:upper:]')
    if [ "$withoutcdn_upper" = "TRUE" ]; then
        export cdn_success_url=""
        echo "WITHOUTCDN=TRUE, skip CDN acceleration"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        echo "CDN available, using CDN"
    else
        echo "No CDN available, no use CDN"
    fi
}

# 设置持久化服务
setup_persistence_service() {
    if [ ! -f /usr/local/bin/add-ipv6.sh ]; then
        if ! wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/add-ipv6.sh" -O /usr/local/bin/add-ipv6.sh; then
            _red "Failed to download add-ipv6.sh"
            _red "下载 add-ipv6.sh 失败"
            exit 1
        fi
        chmod +x /usr/local/bin/add-ipv6.sh
    else
        echo "Script already exists. Skipping installation."
    fi
    if [ ! -f /etc/systemd/system/add-ipv6.service ]; then
        if ! wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/add-ipv6.service" -O /etc/systemd/system/add-ipv6.service; then
            _red "Failed to download add-ipv6.service"
            _red "下载 add-ipv6.service 失败"
            exit 1
        fi
        chmod +x /etc/systemd/system/add-ipv6.service
        service_manager daemon-reload
        service_manager enable add-ipv6.service
        service_manager start add-ipv6.service
    else
        echo "Service already exists. Skipping installation."
    fi
}

# 保存iptables规则 (已废弃，使用save_firewall_rules替代)
save_iptables_rules() {
    save_firewall_rules
}

# 测试IPv6连通性
test_ipv6_connectivity() {
    local ipv6_addr=$1
    if ping6 -c 3 "$ipv6_addr" &>/dev/null; then
        _green "$CONTAINER_NAME The external IPV6 address of the container is $ipv6_addr"
        _green "$CONTAINER_NAME 容器的外网IPV6地址为 $ipv6_addr"
    else
        _red "Mapping failure"
        _red "映射失败"
        exit 1
    fi
}

main() {
    if [ ! -d "$LXD_STATE_DIR" ]; then
        mkdir -p "$LXD_STATE_DIR"
    fi
    disable_legacy_link_local_cleanup
    setup_locale
    CONTAINER_NAME="$1"
    if [[ -z "$CONTAINER_NAME" || "$CONTAINER_NAME" == *[!A-Za-z0-9_.-]* ]]; then
        _red "Invalid LXC container name"
        exit 1
    fi
    use_iptables="${2:-N}"
    use_iptables=$(echo "$use_iptables" | tr '[:upper:]' '[:lower:]')
    # 安装必要的包
    install_package sudo
    install_package lshw
    install_package jq
    install_package net-tools
    install_package cron
    install_package python3
    # 先选择真正拥有公网 IPv6 的接口；没有公网地址时保留双栈容器并
    # 回退到其受管网络的 NAT66，而不是把外部查询结果当作本地地址。
    if ! IPV6=$(check_ipv6 2>/dev/null); then
        configure_ipv6_nat66_fallback
        return 0
    fi
    interface=$(ipv6_uplink_interface "$IPV6" 2>/dev/null || true)
    if [ -z "$interface" ]; then
        _red "No physical network interface found"
        _red "未找到物理网卡"
        configure_ipv6_nat66_fallback
        return 0
    fi
    _yellow "NIC $interface"
    _yellow "网卡 $interface"
    # 等待容器运行
    wait_for_container_status "$CONTAINER_NAME" "RUNNING" 24
    # 获取指定LXC容器的内网IPV6
    CONTAINER_IPV6=$(get_container_ipv6 "$CONTAINER_NAME" 2>/dev/null || true)
    if [ -z "$CONTAINER_IPV6" ]; then
        _red "Container has no intranet IPV6 address, no auto-mapping"
        _red "容器无内网IPV6地址，不进行自动映射"
        configure_ipv6_nat66_fallback
        return 0
    fi
    _blue "The container with the name $CONTAINER_NAME has an intranet IPV6 address of $CONTAINER_IPV6"
    _blue "$CONTAINER_NAME 容器的内网IPV6地址为 $CONTAINER_IPV6"
    # 获取宿主机的IPV6地址（含CIDR）
    ipv6_address=$(ipv6_uplink_cidr "$interface" "$IPV6" 2>/dev/null || true)
    if [[ $ipv6_address == */* ]]; then
        ipv6_length=$(echo "$ipv6_address" | awk -F '/' '{ print $2 }')
        _green "subnet size: $ipv6_length"
        _green "子网大小: $ipv6_length"
    else
        _green "Subnet size for IPV6 not queried"
        _green "查询不到IPV6的子网大小"
        exit 1
    fi
    if ! [[ "$ipv6_length" =~ ^[0-9]+$ ]] || [ "$ipv6_length" -lt 1 ] || [ "$ipv6_length" -gt 128 ]; then
        _red "Invalid IPv6 subnet prefix length: $ipv6_length"
        _red "无效的IPv6子网前缀长度: $ipv6_length"
        exit 1
    fi
    write_atomic_scalar "$(state_file lxd_ipv6_prefix_len)" "$ipv6_length" || exit 1
    IPV6_NETWORK=$(ipv6_allocation_network "$ipv6_address" 2>/dev/null) || {
        _red "Cannot parse host IPv6 network: $ipv6_address"
        configure_ipv6_nat66_fallback
        return 0
    }
    if ! ipv6_pool_has_extra_address "$IPV6_NETWORK" "${ipv6_address%/*}"; then
        configure_ipv6_nat66_fallback
        return 0
    fi
    # fe80检测
    output=$(ip -6 route show | awk '/default via/{print $3}')
    num_lines=$(echo "$output" | wc -l)
    ipv6_gateway=""
    if [ "$num_lines" -eq 1 ]; then
        ipv6_gateway="$output"
    elif [ "$num_lines" -ge 2 ]; then
        non_fe80_lines=$(echo "$output" | grep -v '^fe80')
        if [ -n "$non_fe80_lines" ]; then
            ipv6_gateway=$(echo "$non_fe80_lines" | head -n 1)
        else
            ipv6_gateway=$(echo "$output" | head -n 1)
        fi
    fi
    # 判断fe80是否已加白
    if [[ $ipv6_gateway == fe80* ]]; then
        ipv6_gateway_fe80="Y"
    else
        ipv6_gateway_fe80="N"
    fi
    # 检查是否存在 IPV6
    if [ -z "$IPV6_NETWORK" ]; then
        _red "No IPV6 subnet, no automatic mapping"
        _red "无 IPV6 子网，不进行自动映射"
        exit 1
    fi
    _blue "The IPV6 subnet is $IPV6_NETWORK"
    _blue "宿主机的IPV6子网为 $IPV6_NETWORK"
    # 根据选项决定映射方式
    if [[ $use_iptables == n ]]; then
        setup_network_device_mapping || return 1
    else
        cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
        check_cdn_file
        setup_firewall_mapping
    fi
}

if [ "${ONECLICKVIRT_TESTING:-0}" != "1" ]; then
    main "$@"
fi
