#!/bin/bash
# by https://github.com/oneclickvirt/lxd
# 2026.04.06

# 一键卸载（交互式）：
# curl -L https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/lxduninstall.sh -o lxduninstall.sh && chmod +x lxduninstall.sh && bash lxduninstall.sh
#
# 一键卸载（无交互，环境变量预定义）：
# export noninteractive=true
# bash lxduninstall.sh
#
# export noninteractive=true
# export REMOVE_STORAGE=true
# bash lxduninstall.sh
#
# 可用环境变量：
#   noninteractive=true    跳过确认提示，直接执行卸载 / skip confirmation, uninstall directly
#   REMOVE_STORAGE=true    同时删除存储后端文件（loop 镜像）/ also remove backing storage files

cd /root >/dev/null 2>&1 || exit 1
command -v flock >/dev/null 2>&1 || {
    printf '%s\n' 'flock (util-linux) is required before uninstalling / 卸载前需要安装 util-linux 的 flock。' >&2
    exit 1
}

_red() { printf '\033[31m\033[01m%s\033[0m\n' "$*"; }
_green() { printf '\033[32m\033[01m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[33m\033[01m%s\033[0m\n' "$*"; }
_blue() { printf '\033[36m\033[01m%s\033[0m\n' "$*"; }
reading() { read -rp "$(_green "$1")" "$2"; }

lxd_other_runtime_uses_ipv6_cron() {
    command -v incus >/dev/null 2>&1
}

remove_lxd_ipv6_cron() {
    local cron_file="${OCV_IPV6_CRON_FILE:-/etc/cron.d/oneclickvirt-ipv6}"
    local lock_file="${OCV_IPV6_CRON_LOCK:-/run/lock/oneclickvirt-ipv6.lock}"
    local lock_dir tmp status=0
    local expected="*/1 * * * * root curl --noproxy '*' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb && curl --noproxy '*' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb"

    [ -e "$cron_file" ] || [ -L "$cron_file" ] || return 0
    if lxd_other_runtime_uses_ipv6_cron; then
        _yellow "  检测到 Incus，保留共享 IPv6 定时任务 / Incus detected; preserving shared IPv6 cron."
        return 0
    fi
    if [ -L "$cron_file" ] || [ ! -f "$cron_file" ]; then
        _yellow "  IPv6 cron 不是普通文件，保留人工管理内容 / Preserving non-regular IPv6 cron path."
        return 0
    fi

    (
    lock_dir=${lock_file%/*}
    [ "$lock_dir" != "$lock_file" ] || lock_dir=.
    [ ! -L "$lock_dir" ] || return 1
    mkdir -p -- "$lock_dir" || return 1
    [ ! -L "$lock_file" ] || return 1
    exec {lxd_ipv6_cron_lock_fd}>>"$lock_file" || return 1
    flock -xw 10 "$lxd_ipv6_cron_lock_fd" || return 1
    if [ -L "$cron_file" ] || [ ! -f "$cron_file" ]; then
        flock -u "$lxd_ipv6_cron_lock_fd"
        exec {lxd_ipv6_cron_lock_fd}>&-
        return 0
    fi
    tmp=$(mktemp "${cron_file}.tmp.XXXXXX") || return 1
    cp -p -- "$cron_file" "$tmp" || { rm -f -- "$tmp"; return 1; }
    awk -v expected="$expected" '$0 == expected { removed=1; next } { print } END { exit removed ? 0 : 3 }' \
        "$cron_file" >"$tmp" || status=$?
    if [ "$status" -eq 0 ]; then
        if [ -s "$tmp" ]; then
            mv -f -- "$tmp" "$cron_file" || return 1
        else
            rm -f -- "$cron_file" "$tmp" || return 1
        fi
    elif [ "$status" -eq 3 ]; then
        rm -f -- "$tmp" || return 1
    else
        rm -f -- "$tmp"
        return "$status"
    fi
    flock -u "$lxd_ipv6_cron_lock_fd"
    exec {lxd_ipv6_cron_lock_fd}>&-
    )
}

is_true() {
    local value
    value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [ "$value" = "true" ] || [ "$value" = "1" ] || [ "$value" = "yes" ] || [ "$value" = "y" ]
}

noninteractive="${noninteractive:-${NONINTERACTIVE:-}}"
export noninteractive
if is_true "$noninteractive" || is_true "${FORCE:-}"; then
    noninteractive=true
fi
if is_true "${REMOVE_STORAGE:-}"; then
    REMOVE_STORAGE_UPPER="TRUE"
else
    REMOVE_STORAGE_UPPER="FALSE"
fi

# Keep the recorded path before removing installer state files below.
RECORDED_STORAGE_PATH=""
if [ -r /usr/local/bin/lxd_storage_path ]; then
    IFS= read -r RECORDED_STORAGE_PATH </usr/local/bin/lxd_storage_path || true
fi

remove_lxd_firewalld_bridge() {
    # A surviving interface may now belong to another caller; leave its zone.
    command -v ip >/dev/null 2>&1 || return 1
    if ip link show dev lxdbr0 >/dev/null 2>&1; then return 0; fi
    local state_status=127 zone status scope cli=firewall-cmd
    local options=() scopes=(permanent)
    if command -v firewall-cmd >/dev/null 2>&1; then
        state_status=0
        firewall-cmd --state >/dev/null 2>&1 || state_status=$?
    fi
    if [ "$state_status" -eq 0 ]; then
        scopes+=(runtime)
    elif [ "$state_status" -eq 252 ]; then
        command -v firewall-offline-cmd >/dev/null 2>&1 || return 1
        cli=firewall-offline-cmd
    else
        [ ! -e /etc/firewalld/zones/trusted.xml ] && return 0
        return 1
    fi
    for scope in "${scopes[@]}"; do
        options=()
        if [ "$scope" = permanent ] && [ "$state_status" -eq 0 ]; then options=(--permanent); fi
        status=0
        zone=$(LC_ALL=C "$cli" "${options[@]}" --get-zone-of-interface=lxdbr0 2>&1) || status=$?
        if [ "$status" -eq 0 ] && [ "$zone" = trusted ]; then
            "$cli" "${options[@]}" --zone=trusted --remove-interface=lxdbr0 || return 1
        elif [ "$status" -eq 2 ] && [ "$zone" = 'no zone' ]; then
            :
        elif [ "$status" -ne 0 ]; then
            return 1
        fi
        # Non-trusted zones were never assigned by this installer.
    done
}

ocv_lock_firewall() {
    local lock_dir=/run/oneclickvirt-firewall-locks lock_file
    command -v flock >/dev/null 2>&1 || return 1
    [ ! -L "$lock_dir" ] || return 1
    mkdir -p -m 700 -- "$lock_dir" || return 1
    [ "$(stat -c %u "$lock_dir")" = "$EUID" ] || return 1
    [ "$(stat -c %a "$lock_dir")" = 700 ] || return 1
    lock_file="$lock_dir/firewall.lock"
    [ ! -L "$lock_file" ] || return 1
    exec {ocv_firewall_lock_fd}>>"$lock_file" || return 1
    # Keep the inode: unlinking it would let another process bypass this lock.
    flock -xw 120 "$ocv_firewall_lock_fd" || return 1
}

ocv_with_firewall_lock() {
    # The subshell releases the lock on both success and failure.
    ( ocv_lock_firewall && "$@" )
}

sync_lxd_firewalld_masquerade() {
    local subnet="${1:-}" prefix octet active=false state_status=127
    local permanent_rules="" runtime_rules="" scope rules rule source present
    local cli=firewall-cmd
    local octets=() options=() scopes=(permanent)
    local pattern="^0 -s ([0-9./]+) ['\"]?!['\"]? -o lxdbr0 -m comment --comment ['\"]?oneclickvirt-lxd-ipv4['\"]? -j MASQUERADE$"
    # Validate before changing either scope, preserving working rules on bad
    # runtime metadata. An empty subnet means remove only this installer's NAT.
    if [ -n "$subnet" ]; then
        [[ "$subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
        prefix="${subnet##*/}"
        ((10#$prefix >= 1 && 10#$prefix <= 32)) || return 1
        IFS=. read -r -a octets <<<"${subnet%/*}"
        for octet in "${octets[@]}"; do ((10#$octet <= 255)) || return 1; done
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        state_status=0
        firewall-cmd --state >/dev/null 2>&1 || state_status=$?
        # Only NOT_RUNNING permits offline mutation. A D-Bus failure is not
        # evidence that the daemon stopped; do not overwrite its configuration.
        if [ "$state_status" -ne 0 ] && [ "$state_status" -ne 252 ]; then
            # No saved direct configuration means there is nothing for a
            # stopped/unavailable daemon to restore; kernel cleanup follows.
            [ -z "$subnet" ] && [ ! -e /etc/firewalld/direct.xml ] && return 0
            return 1
        fi
    fi
    if [ "$state_status" -eq 0 ]; then
        active=true
        permanent_rules=$(firewall-cmd --permanent --direct --get-rules ipv4 nat POSTROUTING) || return 1
        runtime_rules=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING) || return 1
        scopes+=(runtime)
    else
        [ -z "$subnet" ] || return 1
        # Retire saved rules through the offline API when the daemon is down,
        # so its next start cannot restore stale NAT. Never edit firewalld XML.
        [ -f /etc/firewalld/direct.xml ] || return 0
        local saved_status=0
        grep -Fq 'oneclickvirt-lxd-ipv4' /etc/firewalld/direct.xml || saved_status=$?
        [ "$saved_status" -ne 1 ] || return 0
        [ "$saved_status" -eq 0 ] || return 1
        [ "$state_status" -eq 252 ] || return 1
        command -v firewall-offline-cmd >/dev/null 2>&1 || return 1
        cli=firewall-offline-cmd
        permanent_rules=$("$cli" --direct --get-rules ipv4 nat POSTROUTING) || return 1
    fi
    for scope in "${scopes[@]}"; do
        options=()
        rules="$permanent_rules"
        if [ "$scope" = runtime ]; then
            rules="$runtime_rules"
        elif [ "$active" = true ]; then
            options=(--permanent)
        fi
        present=false
        while IFS= read -r rule; do
            if [[ "$rule" =~ $pattern ]] && [ "${BASH_REMATCH[1]}" = "$subnet" ]; then present=true; fi
        done <<<"$rules"
        if [ -n "$subnet" ] && [ "$present" = false ]; then
            "$cli" "${options[@]}" --direct --add-rule ipv4 nat POSTROUTING 0 \
                -s "$subnet" ! -o lxdbr0 -m comment --comment oneclickvirt-lxd-ipv4 -j MASQUERADE || return 1
        fi
        # Add the replacement before retiring the old subnet. Rebuild
        # arguments from a strict match; never evaluate firewall output.
        while IFS= read -r rule; do
            if [[ "$rule" =~ $pattern ]]; then
                source="${BASH_REMATCH[1]}"
                if [ -z "$subnet" ] || [ "$source" != "$subnet" ]; then
                    "$cli" "${options[@]}" --direct --remove-rule ipv4 nat POSTROUTING 0 \
                        -s "$source" ! -o lxdbr0 -m comment --comment oneclickvirt-lxd-ipv4 -j MASQUERADE || return 1
                fi
            fi
        done <<<"$rules"
    done
}

remove_lxd_iptables_masquerade() {
    local rules rule source backend="${1:-iptables}"
    local pattern='^-A POSTROUTING -s ([0-9./]+) ! -o lxdbr0 -m comment --comment "?oneclickvirt-lxd-ipv4"? -j MASQUERADE$'
    rules=$("$backend" -w -t nat -S POSTROUTING) || return 1
    while IFS= read -r rule; do
        if [[ "$rule" =~ $pattern ]]; then
            source="${BASH_REMATCH[1]}"
            "$backend" -w -t nat -D POSTROUTING -s "$source" ! -o lxdbr0 -m comment --comment oneclickvirt-lxd-ipv4 -j MASQUERADE || return 1
        fi
    done <<<"$rules"
}

retire_lxd_iptables_masquerade() {
    local backend config_file version
    for backend in iptables-nft iptables-legacy iptables; do
        command -v "$backend" >/dev/null 2>&1 || continue
        version=$("$backend" --version) || return 1
        # An unloaded legacy NAT table contains no rules to retire. Avoid
        # requiring the legacy kernel modules on a host that only uses nft.
        if [[ "$version" == *legacy* ]]; then
            [ -e /proc/net/ip_tables_names ] || continue
            [ -r /proc/net/ip_tables_names ] || return 1
            grep -Fxq nat /proc/net/ip_tables_names || continue
        fi
        remove_lxd_iptables_masquerade "$backend" || return 1
    done
    if [ "$#" -eq 0 ]; then
        set -- /etc/iptables/rules.v4 /etc/sysconfig/iptables /etc/iptables/iptables.rules /etc/iptables/rules-save
    fi
    for config_file in "$@"; do
        remove_lxd_iptables_persistence "$config_file" || return 1
    done
}

remove_lxd_persistent_rules() {
    local config_file="${1:-/etc/nftables.conf}" temporary
    [ -f "$config_file" ] || return 0
    temporary=$(mktemp) || return 1
    if ! awk '
        /^[[:space:]]*include[[:space:]]+"\/etc\/nftables\.d\/oneclickvirt-lxd\.nft"[[:space:]]*;?[[:space:]]*(#.*)?$/ { next }
        /^[[:space:]]*table[[:space:]]+(inet[[:space:]]+(lxd|lxd_nat|lxd_block)|ip6[[:space:]]+lxd_ipv6_nat)[[:space:]]*\{/ { skip=1; depth=0 }
        skip {
            for (i=1; i<=length($0); i++) {
                character=substr($0,i,1)
                if (character=="{") depth++
                else if (character=="}") depth--
            }
            if (depth<=0) skip=0
            next
        }
        { print }
    ' "$config_file" >"$temporary" || ! cat "$temporary" >"$config_file"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
}

remove_lxd_iptables_persistence() {
    local config_file="${1:-/etc/iptables/rules.v4}" temporary
    [ -f "$config_file" ] || return 0
    if [ -L "$config_file" ]; then
        config_file=$(readlink -f -- "$config_file") || return 1
    fi
    temporary=$(mktemp "${config_file}.XXXXXX") || return 1
    # Edit the existing persistent policy, not a dump of unrelated live rules.
    # Keep its permissions and all unowned entries, including legacy NAT.
    if ! cp -p -- "$config_file" "$temporary" || ! awk '
        /^-A POSTROUTING -s [0-9.]+\/[0-9]+ ! -o lxdbr0 -m comment --comment "?oneclickvirt-lxd-ipv4"? -j MASQUERADE$/ { next }
        { print }
    ' "$config_file" >"$temporary" || ! mv -f -- "$temporary" "$config_file"; then
        rm -f -- "$temporary"
        return 1
    fi
}

remove_lxd_fstab_entries() {
    local config_file="${1:-/etc/fstab}" recorded_path="${2:-${RECORDED_STORAGE_PATH:-}}" temporary
    [ -f "$config_file" ] || return 0
    temporary=$(mktemp) || return 1
    # Match both backing file and mountpoint; other btrfs loop files belong to
    # the host or another runtime and must survive an LXD uninstall.
    if ! awk -v recorded="$recorded_path" '
        $3=="btrfs" && $1=="/data/lxd-storage/btrfs_pool.img" && $2=="/data/lxd-storage/btrfs_mount" { next }
        recorded!="" && recorded!="/" && $3=="btrfs" && $1==recorded "/btrfs_pool.img" && $2==recorded "/btrfs_mount" { next }
        { print }
    ' "$config_file" >"$temporary" || ! cat "$temporary" >"$config_file"; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
}

# Inventory in JSON: LXD 5.21 has no -c on project/storage/network list.
runtime_resource_names() {
    local data
    data=$("${LXC_CMD[@]}" "$1" list --format json) || return 1
    jq -sr '
        if length != 1 or (.[0] | type) != "array" then error("invalid runtime inventory")
        else .[0] end |
        if all(.[]; type == "object" and (.name | type) == "string" and (.name | length) > 0)
        then .[].name else error("invalid resource name") end
    ' <<<"$data"
}

# Removing the snap after a failed runtime cleanup hides the cause and can
# strand bridges/mounts. Inventory first, detach profile references while the
# daemon is still available, and keep the installation on a failed removal.
prepare_lxd_runtime_cleanup() {
    local projects project profiles profile devices device
    projects=$(runtime_resource_names project) || return 1
    while IFS= read -r project; do
        [ -z "$project" ] || [ "$project" = default ] || {
            _red "请先清理非默认项目再卸载 / Remove non-default projects before uninstalling: $project"
            return 1
        }
    done <<<"$projects"
    profiles=$("${LXC_CMD[@]}" profile list --format csv -c n) || return 1
    while IFS= read -r profile; do
        [ -n "$profile" ] || continue
        devices=$("${LXC_CMD[@]}" profile device list "$profile") || return 1
        while IFS= read -r device; do
            [ -n "$device" ] || continue
            "${LXC_CMD[@]}" profile device remove "$profile" "$device" || return 1
        done <<<"$devices"
    done <<<"$profiles"
}

remove_lxd_managed_networks() {
    local networks network data
    # The managed property distinguishes daemon-owned bridges from host NICs;
    # the interface name alone is not evidence that LXD owns it.
    data=$("${LXC_CMD[@]}" network list --format json) || return 1
    networks=$(jq -sr '
        if length != 1 or (.[0] | type) != "array" then error("invalid network inventory")
        else .[0] end |
        if all(.[]; type == "object" and (.name | type) == "string" and (.name | length) > 0 and (.managed | type) == "boolean")
        then .[] | select(.managed) | .name else error("unknown network ownership") end
    ' <<<"$data") || return 1
    while IFS= read -r network; do
        [ -n "$network" ] || continue
        "${LXC_CMD[@]}" network delete "$network" || return 1
    done <<<"$networks"
}

remove_recorded_storage_files() {
    local storage_dir="$1"
    if [ -z "$storage_dir" ] || [ ! -d "$storage_dir" ]; then
        return 0
    fi
    if [[ ! "$storage_dir" =~ ^/.+ ]] || [ "$storage_dir" = "/" ]; then
        _yellow "  跳过异常自定义存储路径 / Skipping unsafe storage path: $storage_dir"
        return 0
    fi

    local mount_point="$storage_dir/btrfs_mount"
    if mountpoint -q "$mount_point" 2>/dev/null; then
        _yellow "  卸载自定义 btrfs 挂载点 / Unmounting custom btrfs mount: $mount_point"
        umount "$mount_point" 2>/dev/null || true
    fi

    local storage_file
    for storage_file in \
        "$storage_dir/btrfs_pool.img" \
        "$storage_dir/lvm_pool.img" \
        "$storage_dir/zfs_pool.img" \
        "$storage_dir/lvm_loop_file.txt"; do
        [ -f "$storage_file" ] && rm -f "$storage_file" && _yellow "  已删除 / Removed: $storage_file"
    done

    [ -d "$mount_point" ] && rmdir "$mount_point" 2>/dev/null || true
    if rmdir "$storage_dir" 2>/dev/null; then
        _yellow "  已删除空自定义存储目录 / Removed empty custom storage dir: $storage_dir"
    else
        _yellow "  自定义存储目录非空，已保留 / Custom storage dir not empty, kept: $storage_dir"
    fi
}

# ─── 确认卸载 ────────────────────────────────────────────────────────────────
if ! is_true "${noninteractive:-}"; then
    echo ""
    _red "======================================================"
    _red "  警告：此操作将彻底卸载 LXD 及相关所有组件！"
    _red "  WARNING: This will completely remove LXD and all"
    _red "           related components!"
    _red "  所有 LXC 容器和存储池数据将被永久销毁！"
    _red "  All LXC containers and storage pool data will be"
    _red "  PERMANENTLY DESTROYED!"
    _red "======================================================"
    echo ""
    reading "确认要继续？(y/n) [n] / Confirm continue? (y/n) [n]: " confirm
    confirm=${confirm:-n}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        _yellow "已取消卸载。/ Uninstall cancelled."
        exit 0
    fi
    echo ""
    reading "是否同时删除存储后端文件（loop 镜像等）？(y/n) [n] / Also remove backing storage files? (y/n) [n]: " rs_input
    rs_input=${rs_input:-n}
    if [[ "$rs_input" =~ ^[yY]$ ]]; then
        REMOVE_STORAGE_UPPER="TRUE"
    fi
fi

_green "开始卸载 LXD... / Starting LXD uninstall..."
echo ""

# ─── 1. 停止并删除所有 LXC 容器 ──────────────────────────────────────────────
_blue "[1/9] 停止并删除所有 LXC 容器 / Stopping and deleting all LXC containers..."

if command -v lxc >/dev/null 2>&1 || [ -x /snap/bin/lxc ]; then
    LXC_CMD=(lxc --force-local --project default)
    ! command -v lxc >/dev/null 2>&1 && LXC_CMD=(/snap/bin/lxc --force-local --project default)

    # Check project scope before deleting anything. The following CLI commands
    # operate on default; removing the snap would also destroy other projects.
    projects=$(runtime_resource_names project) || exit 1
    if [ "$projects" != default ]; then
        _red "请先清理非默认项目再卸载 / Remove non-default projects before uninstalling."
        exit 1
    fi
    containers=$("${LXC_CMD[@]}" list --format=csv -c n) || exit 1
    if [ -n "$containers" ]; then
        while IFS= read -r ct; do
            [ -z "$ct" ] && continue
            _yellow "  正在停止 / Stopping: $ct"
            # delete --force also handles instances which are already stopped.
            _yellow "  正在删除 / Deleting: $ct"
            "${LXC_CMD[@]}" delete "$ct" --force || exit 1
        done <<< "$containers"
        _green "  已删除所有容器 / All containers deleted."
    else
        _green "  无容器需要删除 / No containers found."
    fi
else
    _yellow "  lxc 命令不可用，跳过容器清理 / lxc not available, skipping container cleanup."
fi

# ─── 2. 清理 LXD 存储池 ──────────────────────────────────────────────────────
_blue "[2/9] 清理 LXD 存储池 / Cleaning up LXD storage pools..."

if command -v lxc >/dev/null 2>&1 || [ -x /snap/bin/lxc ]; then
    LXC_CMD=(lxc --force-local --project default)
    ! command -v lxc >/dev/null 2>&1 && LXC_CMD=(/snap/bin/lxc --force-local --project default)
    prepare_lxd_runtime_cleanup || exit 1
    # 获取存储类型和路径
    storage_type=""
    if [ -f /usr/local/bin/lxd_storage_type ]; then
        storage_type=$(cat /usr/local/bin/lxd_storage_type 2>/dev/null)
        _yellow "  检测到存储类型 / Detected storage type: $storage_type"
    fi

    # 尝试删除所有存储池中的卷
    pool_list=$(runtime_resource_names storage) || exit 1
    if [ -n "$pool_list" ]; then
        while IFS= read -r pool; do
            [ -z "$pool" ] && continue
            pool=$(echo "$pool" | tr -d '[:space:]')
            _yellow "  正在清空并删除存储池 / Cleaning pool: $pool"
            # 删除该池中的所有卷
            volumes=$("${LXC_CMD[@]}" storage volume list "$pool" --format=csv -c tn) || exit 1
            if [ -n "$volumes" ]; then
                while IFS=, read -r volume_type vol; do
                    [ -z "$vol" ] && continue
                    vol=$(echo "$vol" | tr -d '[:space:]')
                    # Image cache volumes are owned by the daemon and removed
                    # with the pool; container/VM volumes should be gone above.
                    [ "$volume_type" = image ] && continue
                    "${LXC_CMD[@]}" storage volume delete "$pool" "$volume_type/$vol" || exit 1
                done <<< "$volumes"
            fi
            # 删除存储池
            "${LXC_CMD[@]}" storage delete "$pool" || exit 1
        done <<< "$pool_list"
        _green "  存储池已清理 / Storage pools cleaned."
    else
        _green "  无存储池需要清理 / No storage pools found."
    fi

    remove_lxd_managed_networks || exit 1

    # 清理 btrfs loop 挂载
    if [ "$storage_type" = "btrfs" ] || mountpoint -q /mnt/lxd_btrfs 2>/dev/null; then
        mount_points=(/mnt/lxd_btrfs /data/lxd-storage/btrfs_mount)
        if [[ "$RECORDED_STORAGE_PATH" == /* && "$RECORDED_STORAGE_PATH" != / ]]; then
            mount_points+=("$RECORDED_STORAGE_PATH/btrfs_mount")
        fi
        for mount_point in "${mount_points[@]}"; do
            if mountpoint -q "$mount_point"; then
                _yellow "  卸载 btrfs 挂载点 / Unmounting btrfs: $mount_point"
                umount "$mount_point" || exit 1
            fi
        done
    fi

    # 清理 LVM vgroup
    if [ "$storage_type" = "lvm" ] && command -v vgremove >/dev/null 2>&1; then
        _yellow "  清理 LVM 卷组 / Removing LVM volume group: lxd_vg"
        vgremove -f lxd_vg 2>/dev/null || true
        # 清理 loop 设备
        for loop_dev in $(losetup -j /var/snap/lxd/common/lxd/disks/default.img 2>/dev/null | cut -d: -f1); do
            losetup -d "$loop_dev" 2>/dev/null || true
        done
    fi

    # 清理 ZFS pool
    if [ "$storage_type" = "zfs" ] && command -v zpool >/dev/null 2>&1; then
        _yellow "  清理 ZFS pool / Removing ZFS pool: lxd_zfs_pool"
        zpool destroy -f lxd_zfs_pool 2>/dev/null || true
    fi

    # 删除存储后端文件
    if [ "$REMOVE_STORAGE_UPPER" = "TRUE" ]; then
        _yellow "  删除存储后端 loop 文件 / Removing backing storage files..."
        # snap 默认存储目录下的镜像文件
        rm -f /var/snap/lxd/common/lxd/disks/default.img 2>/dev/null || true
        rm -f /var/snap/lxd/common/lxd/disks/*.img 2>/dev/null || true
        # 用户自定义路径下的 loop 文件（btrfs/lvm/zfs）
        for img in \
            /data/lxd-storage/btrfs_pool.img \
            /data/lxd-storage/lvm_pool.img \
            /data/lxd-storage/zfs_pool.img; do
            [ -f "$img" ] && rm -f "$img" && _yellow "  已删除 / Removed: $img"
        done
        # 通过记录的自定义路径查找。只删除本脚本创建的已知后端文件，不递归删除整个目录。
        if [ -f /usr/local/bin/lxd_storage_path ]; then
            sp=$(cat /usr/local/bin/lxd_storage_path 2>/dev/null)
            remove_recorded_storage_files "$sp"
        fi
        _green "  存储后端文件已清理 / Backing storage files removed."
    fi
else
    _yellow "  lxc 命令不可用，跳过存储池清理 / lxc not available, skipping pool cleanup."
fi

# ─── 3. 卸载 LXD snap ────────────────────────────────────────────────────────
_blue "[3/9] 卸载 LXD snap / Removing LXD snap..."

if command -v snap >/dev/null 2>&1; then
    snap_inventory=$(snap list) || exit 1
    if awk '$1=="lxd" { found=1 } END { exit !found }' <<<"$snap_inventory"; then
        if ! snap remove lxd; then
            _red "LXD snap 卸载失败，停止后续清理 / LXD snap removal failed; stopping cleanup."
            exit 1
        fi
        _green "  LXD snap 已卸载 / LXD snap removed."
    else
        _yellow "  LXD snap 不存在 / LXD snap is not installed."
    fi
else
    _yellow "  snap 不可用，跳过 / snap not available, skipping."
fi

# ─── 4. 卸载守护服务 ──────────────────────────────────────────────────────────
_blue "[4/9] 卸载守护服务 / Removing background services..."

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop check-dns.service 2>/dev/null || true
    systemctl disable check-dns.service 2>/dev/null || true
    systemctl stop add-ipv6.service 2>/dev/null || true
    systemctl disable add-ipv6.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
fi
rm -f /etc/systemd/system/check-dns.service
rm -f /etc/systemd/system/add-ipv6.service
_green "  守护服务已移除 / Background services removed."

# ─── 5. 删除安装的文件 ───────────────────────────────────────────────────────
_blue "[5/9] 删除安装的文件 / Removing installed files..."

files_to_remove=(
    /usr/local/bin/ssh_bash.sh
    /usr/local/bin/ssh_sh.sh
    /usr/local/bin/config.sh
    /usr/local/bin/instance_ownership.sh
    /root/instance_ownership.sh
    /usr/local/bin/check-dns.sh
    /usr/local/bin/add-ipv6.sh
    /usr/local/bin/remove_route.sh
    /usr/local/bin/lxd_storage_type
    /usr/local/bin/lxd_storage_path
    /usr/local/bin/lxd_storage_pool
    /usr/local/bin/lxd_tried_storage
    /usr/local/bin/lxd_installed_storage
    /usr/local/bin/incus_tried_storage
    /usr/local/bin/incus_installed_storage
    /usr/local/bin/lxd_reboot
    /usr/local/bin/lxd_check_ipv6
    /usr/local/bin/lxd_ipv6_prefix_len
    /root/ssh_bash.sh
    /root/ssh_sh.sh
    /root/config.sh
)
for f in "${files_to_remove[@]}"; do
    [ -f "$f" ] && rm -f "$f" && _yellow "  已删除 / Removed: $f"
done
remove_lxd_ipv6_cron || exit 1
_green "  文件清理完成 / File cleanup done."

# ─── 6. 清理 iptables 规则 ───────────────────────────────────────────────────
_blue "[6/9] 清理防火墙规则 / Cleaning up firewall rules..."
ocv_lock_firewall || exit 1
sync_lxd_firewalld_masquerade || exit 1
remove_lxd_firewalld_bridge || exit 1

# 清理 nftables 规则
for nft_config_file in /etc/nftables.conf /etc/sysconfig/nftables.conf /etc/nftables.nft; do
    remove_lxd_persistent_rules "$nft_config_file" || exit 1
done
rm -f -- /etc/nftables.d/oneclickvirt-lxd.nft || exit 1
if command -v nft >/dev/null 2>&1; then
    nft delete table inet lxd_nat 2>/dev/null || true
    nft delete table inet lxd_block 2>/dev/null || true
    nft delete table ip6 lxd_ipv6_nat 2>/dev/null || true
    nft delete table inet lxd 2>/dev/null || true
    _green "  nftables 规则已清理 / nftables rules cleaned."
fi

# 清理 iptables 规则
retire_lxd_iptables_masquerade || exit 1
# Legacy untagged host-wide rules cannot be distinguished from rules
# shared by other runtimes. Keep them; only delete our tagged IPv4 NAT.
_green "  iptables 规则已清理 / iptables rules cleaned."

# ─── 7. 清理 /etc/fstab 中的 btrfs loop 行 ──────────────────────────────────
_blue "[7/9] 清理 /etc/fstab / Cleaning /etc/fstab..."

if [ -f /etc/fstab ]; then
    remove_lxd_fstab_entries || exit 1
    _green "  /etc/fstab 已清理 / /etc/fstab cleaned."
fi

# ─── 8. 保留共享的宿主转发设置 ──────────────────────────────────────────────
# There is no recorded previous value or exclusive ownership of these host
# settings. Disabling forwarding can disconnect other runtimes and routers.
_blue "[8/9] 保留宿主机共享转发设置 / Preserving shared host forwarding settings."

# ─── 9. 清理 /etc/security/limits.conf 和 logind.conf ───────────────────────
_blue "[9/9] 清理系统限制配置 / Cleaning system limits config..."

if [ -f /etc/security/limits.conf ]; then
    sed -i '/^\*[[:space:]]*hard[[:space:]]*nproc[[:space:]]*unlimited/d' /etc/security/limits.conf 2>/dev/null || true
    sed -i '/^\*[[:space:]]*soft[[:space:]]*nproc[[:space:]]*unlimited/d' /etc/security/limits.conf 2>/dev/null || true
fi
if [ -f /etc/systemd/logind.conf ]; then
    sed -i '/^UserTasksMax=infinity/d' /etc/systemd/logind.conf 2>/dev/null || true
fi
_green "  系统限制配置已清理 / System limits config cleaned."

echo ""
_green "======================================================"
_green "  LXD 卸载完成！/ LXD uninstall complete!"
_green "======================================================"
echo ""
_yellow "建议重启系统以确保所有更改生效。"
_yellow "It is recommended to reboot the system to apply all changes."
