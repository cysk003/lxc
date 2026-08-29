#!/bin/bash
# from
# https://github.com/oneclickvirt/lxd
# 2026.08.30

# cd /root
red() { printf '\033[31m\033[01m%s\033[0m\n' "$*"; }
green() { printf '\033[32m\033[01m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m\033[01m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m\033[01m%s\033[0m\n' "$*"; }
reading() { read -rp "$(green "$1")" "$2"; }

is_true() {
    local value
    value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [ "$value" = "true" ] || [ "$value" = "1" ] || [ "$value" = "yes" ] || [ "$value" = "y" ]
}

env_value() {
    local upper_name="$1"
    local lower_name="$2"
    local default_value="$3"
    local value="${!upper_name:-}"
    if [ -z "$value" ]; then
        value="${!lower_name:-}"
    fi
    printf '%s' "${value:-$default_value}"
}

validate_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_non_negative_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_positive_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$1" 'BEGIN { exit !(n > 0) }'
}

normalize_ipv6_status() {
    local value
    value=$(printf '%s' "${1:-N}" | tr '[:lower:]' '[:upper:]')
    if [ "$value" = "Y" ] || [ "$value" = "YES" ] || [ "$value" = "TRUE" ] || [ "$value" = "1" ]; then
        printf 'Y'
    else
        printf 'N'
    fi
}

strip_image_separators() {
    local value="$1"
    while [[ "$value" == [/:_.-]* ]]; do
        value="${value#?}"
    done
    while [[ "$value" == *[/:_.-] ]]; do
        value="${value%?}"
    done
    printf '%s\n' "$value"
}

canonical_image_family() {
    local family="$1"
    case "$family" in
    alma) family="almalinux" ;;
    rocky) family="rockylinux" ;;
    oraclelinux | oracle-linux | oracle_linux) family="oracle" ;;
    arch) family="archlinux" ;;
    esac
    printf '%s\n' "$family"
}

normalize_image_system() {
    local raw="${1:-}"
    local input prefix
    input="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    input="${input#images:}"
    input="${input#opsmaru:}"
    input="$(strip_image_separators "$input")"
    if [ -z "$input" ]; then
        return 1
    fi
    if [[ "$input" == */* ]]; then
        a="${input%%/*}"
        b="${input#*/}"
        b="${b%%/*}"
    else
        prefix="${input%%[0-9]*}"
        if [ "$prefix" != "$input" ]; then
            a="$prefix"
            b="${input#"$prefix"}"
        else
            a="$input"
            b=""
        fi
    fi
    a="$(strip_image_separators "$a")"
    b="$(strip_image_separators "$b")"
    a="$(canonical_image_family "$a")"
    normalized_system="${a}${b}"
    [ -n "$a" ]
}

image_name_matches_system() {
    local image_name="$1"
    [ -n "${a:-}" ] || return 1
    if [ -z "${b:-}" ]; then
        [[ "$image_name" == "${a}_"* ]]
        return
    fi
    [[ "$image_name" == "${a}_${b}"* ]]
}

find_matching_image_from_stream() {
    local image_name
    while IFS= read -r image_name; do
        [ -n "$image_name" ] || continue
        if image_name_matches_system "$image_name"; then
            printf '%s\n' "$image_name"
            return 0
        fi
    done
    return 1
}

remote_image_query() {
    if [ -n "${b:-}" ]; then
        printf '%s/%s\n' "$a" "$b"
    else
        printf '%s\n' "$a"
    fi
}

find_remote_image_alias() {
    local remote="$1"
    local image_type="$2"
    local query
    command -v lxc >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    query="$(remote_image_query)"
    lxc image list "${remote}:${query}" --format=json 2>/dev/null | jq -r --arg ARCHITECTURE "${sys_bit:-}" --arg ARCHITECTURE_ALT "${sys_bit_alt:-}" --arg IMAGE_TYPE "$image_type" '
        .[]?
        | select((.type // "") == $IMAGE_TYPE)
        | select($ARCHITECTURE == "" or (.architecture // "") == $ARCHITECTURE or ($ARCHITECTURE_ALT != "" and (.architecture // "") == $ARCHITECTURE_ALT))
        | .aliases[]?
        | .name // empty
        | select(length > 0)
    ' | head -n 1
}

detect_image_arch() {
    sys_bit=""
    sys_bit_alt=""
    self_image_arch=""
    sysarch="$(uname -m)"
    case "${sysarch}" in
    "x86_64" | "x86" | "amd64" | "x64")
        sys_bit="x86_64"
        sys_bit_alt="amd64"
        self_image_arch="x86_64"
        ;;
    "i386" | "i686")
        sys_bit="i686"
        sys_bit_alt="i386"
        ;;
    "aarch64" | "armv8" | "armv8l")
        sys_bit="aarch64"
        sys_bit_alt="arm64"
        self_image_arch="arm64"
        ;;
    "armv7l")
        sys_bit="armv7l"
        sys_bit_alt="armhf"
        ;;
    "s390x") sys_bit="s390x" ;;
    "ppc64le") sys_bit="ppc64le" ;;
    *)
        sys_bit="x86_64"
        sys_bit_alt="amd64"
        self_image_arch="x86_64"
        ;;
    esac
}

container_system_available() {
    local matched_image
    if [ -n "${self_image_arch:-}" ]; then
        matched_image=$(curl -fsSLk -m 10 "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/lxd_images/main/${self_image_arch}_all_images.txt" 2>/dev/null | find_matching_image_from_stream)
        if [ -n "$matched_image" ]; then
            return 0
        fi
    fi
    matched_image="$(find_remote_image_alias images container)"
    if [ -n "$matched_image" ]; then
        return 0
    fi
    matched_image="$(find_remote_image_alias opsmaru container)"
    [ -n "$matched_image" ]
}

if [ "${ONECLICKVIRT_TESTING:-}" != "1" ]; then
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
    if [[ -z "$utf8_locale" ]]; then
        yellow "No UTF-8 locale found"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        green "Locale set to $utf8_locale"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        apt-get install jq -y
    fi
fi

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

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
if [ "${ONECLICKVIRT_TESTING:-}" != "1" ]; then
    check_cdn_file
fi

download_file() {
    local url="$1"
    local output="$2"
    if ! curl -fsSLk "${cdn_success_url}${url}" -o "$output"; then
        red "Failed to download: $url"
        red "下载失败：$url"
        exit 1
    fi
}

pre_check() {
    home_dir=$(eval echo "~$(whoami)")
    if [ "$home_dir" != "/root" ]; then
        red "Current path is not /root, script will exit."
        red "当前路径不是/root，脚本将退出。"
        exit 1
    fi
    if ! command -v dos2unix >/dev/null 2>&1; then
        apt-get install dos2unix -y
    fi
    if [ ! -f ssh_bash.sh ]; then
        download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_bash.sh" ssh_bash.sh
        chmod 777 ssh_bash.sh
        dos2unix ssh_bash.sh
    fi
    if [ ! -f ssh_sh.sh ]; then
        download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_sh.sh" ssh_sh.sh
        chmod 777 ssh_sh.sh
        dos2unix ssh_sh.sh
    fi
    if [ ! -f config.sh ]; then
        download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/config.sh" config.sh
        chmod 777 config.sh
        dos2unix config.sh
    fi
    if [ ! -f buildct.sh ]; then
        download_file "https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/buildct.sh" buildct.sh
        chmod 777 buildct.sh
        dos2unix buildct.sh
    fi
}

check_log() {
    log_file="log"
    if [ -f "$log_file" ]; then
        green "Log file exists, content being read..."
        green "Log文件存在，正在读取内容..."
        while IFS= read -r line; do
            # echo "$line"
            last_line="$line"
        done <"$log_file"
        read -r -a last_line_array <<< "$last_line"
        container_name="${last_line_array[0]}"
        ssh_port="${last_line_array[1]}"
        public_port_start="${last_line_array[3]}"
        public_port_end="${last_line_array[4]}"
        if [ -z "$public_port_start" ] || [ -z "$public_port_end" ]; then
            if is_true "${noninteractive:-}" || is_true "${NONINTERACTIVE:-}"; then
                yellow "Log lacks NAT port range, noninteractive mode will use defaults or environment overrides."
                yellow "log 缺少 NAT 端口范围，无交互模式将使用默认值或环境变量覆盖值。"
                public_port_end=30000
            else
                blue "Only the common version of the configuration batch repeat generation is supported, pure probe version or other can not be used"
                blue "仅支持普通版本的配置批量重复生成，纯探针版本或其他的无法使用"
                exit 1
            fi
        fi
        container_prefix="${container_name%%[0-9]*}"
        container_num="${container_name##*[!0-9]}"
        if ! validate_non_negative_int "$container_num"; then
            container_num=0
        fi
        [ -n "$container_prefix" ] || container_prefix="ex"
        [ -n "$ssh_port" ] || ssh_port=20000
        [ -n "$public_port_end" ] || public_port_end=30000
        yellow "Current information on the last container:"
        yellow "目前最后一个容器的信息："
        blue "容器前缀-Prefix: $container_prefix"
        blue "容器数量-num: $container_num"
        blue "SSH端口-ssh: $ssh_port"
        #         blue "密码: $password"
        blue "外网端口起-portstart: $public_port_start"
        blue "外网端口止-portend: $public_port_end"
    else
        red "Log file does not exist."
        red "log文件不存在。"
        container_prefix="ex"
        container_num=0
        ssh_port=20000
        public_port_end=30000
    fi

}

add_batch_active=false
add_batch_pending_log=""
add_batch_commit_log=""
add_batch_created=()

lxc_instance_exists() {
    lxc info "$1" >/dev/null 2>&1
}

track_add_batch_instance() {
    local candidate="$1"
    local tracked
    for tracked in "${add_batch_created[@]}"; do
        [ "$tracked" = "$candidate" ] && return 0
    done
    add_batch_created+=("$candidate")
}

rollback_add_batch() {
    local index container_name
    for ((index = ${#add_batch_created[@]} - 1; index >= 0; index--)); do
        container_name="${add_batch_created[index]}"
        lxc delete --force "$container_name" >/dev/null 2>&1 || true
        rm -f -- "$container_name"
    done
    [ -z "$add_batch_pending_log" ] || rm -f -- "$add_batch_pending_log"
    [ -z "$add_batch_commit_log" ] || rm -f -- "$add_batch_commit_log"
    add_batch_created=()
    add_batch_pending_log=""
    add_batch_commit_log=""
    add_batch_active=false
}

cleanup_add_batch() {
    local status=$?
    if [ "$add_batch_active" = true ]; then
        rollback_add_batch
    fi
    return "$status"
}

begin_add_batch() {
    add_batch_pending_log=$(mktemp .log.pending.XXXXXX) || return 1
    add_batch_active=true
    trap cleanup_add_batch EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

commit_add_batch_log() {
    add_batch_commit_log=$(mktemp .log.commit.XXXXXX) || return 1
    if [ -f log ] && ! cat log >"$add_batch_commit_log"; then
        return 1
    fi
    if ! cat "$add_batch_pending_log" >>"$add_batch_commit_log"; then
        return 1
    fi
    mv -f -- "$add_batch_commit_log" log || return 1
    add_batch_commit_log=""
}

build_new_containers() {
    if is_true "${noninteractive:-}" || is_true "${NONINTERACTIVE:-}"; then
        noninteractive=true
        container_prefix=$(env_value CONTAINER_PREFIX container_prefix "$container_prefix")
        container_num=$(env_value CONTAINER_NUM container_num "$container_num")
        ssh_port=$(env_value SSH_PORT ssh_port "$ssh_port")
        public_port_end=$(env_value PUBLIC_PORT_END public_port_end "$public_port_end")
        new_nums=$(env_value NEW_NUMS new_nums 1)
        cpu_nums=$(env_value CPU_NUMS cpu_nums 1)
        memory_nums=$(env_value MEMORY_NUMS memory_nums 256)
        disk_nums=$(env_value DISK_NUMS disk_nums 1)
        input_nums=$(env_value INPUT_NUMS input_nums 300)
        output_nums=$(env_value OUTPUT_NUMS output_nums 300)
        is_enabled_ipv6=$(env_value ENABLE_IPV6 enable_ipv6 "")
        if [ -z "$is_enabled_ipv6" ]; then
            is_enabled_ipv6=$(env_value STATUS_IPV6 status_ipv6 N)
        fi
        system=$(env_value SYSTEM_IMAGE system_image "")
        if [ -z "$system" ]; then
            system=$(env_value CT_SYSTEM ct_system "")
        fi
        if [ -z "$system" ]; then
            system=$(env_value SYSTEM system debian12)
        fi
        green "noninteractive=true, using preset values for batch creation"
        green "noninteractive=true，使用预设参数批量创建容器"
    else
        while true; do
            green "How many more containers need to be generated? (Enter how many new containers to add):"
            reading "还需要生成几个容器？(输入新增几个容器)：" new_nums
            if validate_positive_int "$new_nums"; then
                break
            else
                yellow "Invalid input, please enter a positive integer."
                yellow "输入无效，请输入一个正整数。"
            fi
        done
        while true; do
            green "How many Cores are allocated per container? (Number of CPU cores per container, if you need 1 core, enter 1):"
            reading "每个容器分配几个CPU？(每个容器CPU核数，若需要1核，输入1)：" cpu_nums
            if validate_positive_int "$cpu_nums"; then
                break
            else
                yellow "Invalid input, please enter a positive integer."
                yellow "输入无效，请输入一个正整数。"
            fi
        done
        while true; do
            green "How much memory is allocated per container? (Memory size per container, enter 256 if 256MB of memory is required):"
            reading "每个容器分配多少内存？(每个容器内存大小，若需要256MB内存，输入256)：" memory_nums
            if validate_positive_int "$memory_nums"; then
                break
            else
                yellow "Invalid input, please enter a positive integer."
                yellow "输入无效，请输入一个正整数。"
            fi
        done
        while true; do
            green "What size hard disk is allocated for each container? (per container hard drive size, enter 1 if 1G hard drive is required):"
            reading "每个容器分配多大硬盘？(每个容器硬盘大小，若需要1G硬盘，输入1)：" disk_nums
            if validate_positive_number "$disk_nums"; then
                break
            else
                yellow "Invalid input, please enter a positive num."
                yellow "输入无效，请输入一个正数。"
            fi
        done
        while true; do
            green "What is the download speed limit per container? (If you need the limit to be 300Mbit, enter 300):"
            reading "每个容器下载速度限制多少？(若需要限制为300Mbit，输入300)：" input_nums
            if validate_positive_int "$input_nums"; then
                break
            else
                yellow "Invalid input, please enter a positive integer."
                yellow "输入无效，请输入一个正整数。"
            fi
        done
        while true; do
            green "What is the upload speed limit per container? (If you need the limit to be 300Mbit, enter 300):"
            reading "每个容器上传速度限制多少？(若需要限制为300Mbit，输入300)：" output_nums
            if validate_positive_int "$output_nums"; then
                break
            else
                yellow "Invalid input, please enter a positive integer."
                yellow "输入无效，请输入一个正整数。"
            fi
        done
        green "Is IPV6 enabled for each chick?(Leave blank N by default, no V6 address is set):"
        reading "每个容器是否启用IPV6？(默认留空为N，不设置V6地址)：" is_enabled_ipv6
        detect_image_arch
        while true; do
            green "What is the system of each container? (e.g. debian11, debian/11, ubuntu20, centos7):"
            reading "每个容器的系统是什么？(如：debian11、debian/11、ubuntu20、centos7)：" system
            system="${system:-debian12}"
            if ! normalize_image_system "$system"; then
                yellow "Invalid input, please enter an existing system."
                yellow "输入无效，请输入一个存在的系统"
                continue
            fi
            system="$normalized_system"
            if container_system_available; then
                echo "Matching mirror exists"
                echo "匹配的镜像存在"
                break
            else
                echo "No matching image found, please execute"
                echo "lxc image list images:system/version_number OR lxc image list opsmaru:system/version_number"
                echo "Check if the corresponding image exists"
                echo "未找到匹配的镜像，请执行"
                echo "lxc image list images:系统/版本号 或 lxc image list opsmaru:系统/版本号"
                echo "查询是否存在对应镜像"
                yellow "输入无效，请输入一个存在的系统"
            fi
        done
    fi

    if ! validate_positive_int "$new_nums"; then
        red "NEW_NUMS must be a positive integer."
        red "NEW_NUMS 必须是正整数。"
        exit 1
    fi
    if ! validate_non_negative_int "$container_num" || ! validate_positive_int "$ssh_port" || ! validate_non_negative_int "$public_port_end"; then
        red "Container index and port values are invalid."
        red "容器序号或端口参数无效。"
        exit 1
    fi
    if [ $((ssh_port + new_nums)) -gt 65535 ]; then
        red "Generated SSH ports would exceed 65535."
        red "生成后的 SSH 端口会超过 65535。"
        exit 1
    fi
    if [ $((public_port_end + new_nums * 25)) -gt 65535 ]; then
        red "Generated NAT ports would exceed 65535."
        red "生成后的 NAT 端口会超过 65535。"
        exit 1
    fi
    if ! validate_positive_int "$cpu_nums" || ! validate_positive_int "$memory_nums" || ! validate_positive_int "$input_nums" || ! validate_positive_int "$output_nums"; then
        red "CPU, memory and speed values must be positive integers."
        red "CPU、内存和网速参数必须是正整数。"
        exit 1
    fi
    if ! validate_positive_number "$disk_nums"; then
        red "DISK_NUMS must be a positive number."
        red "DISK_NUMS 必须是正数。"
        exit 1
    fi
    system="${system:-debian12}"
    if ! normalize_image_system "$system"; then
        red "SYSTEM_IMAGE must be a valid system name, such as debian12 or debian/12."
        red "SYSTEM_IMAGE 必须是有效系统名称，例如 debian12 或 debian/12。"
        exit 1
    fi
    system="$normalized_system"
    status_ipv6=$(normalize_ipv6_status "$is_enabled_ipv6")

    if ! begin_add_batch; then
        red "无法创建批量日志暂存文件"
        red "Unable to create the batch log staging file"
        return 1
    fi

    for ((i = 1; i <= new_nums; i++)); do
        container_num=$(($container_num + 1))
        container_name="${container_prefix}${container_num}"
        ssh_port=$(($ssh_port + 1))
        public_port_start=$(($public_port_end + 1))
        public_port_end=$(($public_port_start + 24))
        if lxc_instance_exists "$container_name"; then
            red "容器 ${container_name} 已存在，未修改既有实例"
            red "Container ${container_name} already exists; the existing instance was not changed"
            return 1
        fi
        if ./buildct.sh "$container_name" "$cpu_nums" "$memory_nums" "$disk_nums" "$ssh_port" "$public_port_start" "$public_port_end" "$input_nums" "$output_nums" "$status_ipv6" "$system"; then
            track_add_batch_instance "$container_name"
        else
            build_status=$?
            if lxc_instance_exists "$container_name"; then
                track_add_batch_instance "$container_name"
            fi
            red "容器 ${container_name} 创建失败，已停止后续批量创建"
            red "Container ${container_name} creation failed; remaining batch items were not started"
            rm -f -- "$container_name"
            return "$build_status"
        fi
        if [ ! -s "$container_name" ]; then
            red "容器 ${container_name} 未生成成功记录，已停止后续批量创建"
            rm -f -- "$container_name"
            return 1
        fi
        if ! cat "$container_name" >>"$add_batch_pending_log"; then
            red "容器 ${container_name} 成功记录暂存失败"
            rm -f -- "$container_name"
            return 1
        fi
        rm -f -- "$container_name"
    done
    if ! commit_add_batch_log; then
        red "批量日志提交失败，正在回滚本批次容器"
        return 1
    fi
    rm -f -- "$add_batch_pending_log"
    add_batch_pending_log=""
    add_batch_created=()
    add_batch_active=false
}

if [ "${ONECLICKVIRT_TESTING:-}" != "1" ]; then
    pre_check
    check_log
    if ! build_new_containers; then
        exit 1
    fi
    green "Generating new chicks is complete"
    green "生成新的容器完毕"
    check_log
fi
