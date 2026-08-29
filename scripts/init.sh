#!/usr/bin/env bash
# from
# https://github.com/oneclickvirt/lxd
# cd /root
# ./init.sh NAT服务器前缀 数量
# 2026.08.30

if [ "${ONECLICKVIRT_TESTING:-}" != "1" ]; then
  cd /root >/dev/null 2>&1 || exit 1
  if [ ! -d "/usr/local/bin" ]; then
    mkdir -p "/usr/local/bin"
  fi
fi

lxd_storage_pool() {
  local pool_name="${LXD_STORAGE_POOL:-}"
  if [ -z "$pool_name" ] && [ -r /usr/local/bin/lxd_storage_pool ]; then
    IFS= read -r pool_name </usr/local/bin/lxd_storage_pool || true
  fi
  [[ "$pool_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || pool_name="default"
  printf '%s\n' "$pool_name"
}

batch_active=false
batch_pending_log=""
batch_created=()

lxc_instance_exists() {
  lxc info "$1" >/dev/null 2>&1
}

track_batch_instance() {
  local candidate="$1"
  local tracked
  for tracked in "${batch_created[@]}"; do
    [ "$tracked" = "$candidate" ] && return 0
  done
  batch_created+=("$candidate")
}

rollback_batch() {
  local index instance_name
  for ((index = ${#batch_created[@]} - 1; index >= 0; index--)); do
    instance_name="${batch_created[index]}"
    lxc delete --force "$instance_name" >/dev/null 2>&1 || true
  done
  [ -z "$batch_pending_log" ] || rm -f -- "$batch_pending_log"
  batch_created=()
  batch_pending_log=""
  batch_active=false
}

cleanup_failed_batch() {
  local status=$?
  if [ "$batch_active" = true ]; then
    rollback_batch
  fi
  return "$status"
}

begin_batch() {
  batch_pending_log=$(mktemp .log.pending.XXXXXX) || return 1
  batch_active=true
  trap cleanup_failed_batch EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

commit_batch_log() {
  [ -s "$batch_pending_log" ] || return 1
  mv -f -- "$batch_pending_log" log || return 1
  batch_pending_log=""
  batch_created=()
  batch_active=false
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

check_china() {
  echo "IP area being detected ......"
  if [[ -z "${CN}" ]]; then
    if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
      echo "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
      CN=true
    fi
  fi
}

validate_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_inputs() {
  if [ -z "${1:-}" ] || ! validate_positive_int "${2:-}"; then
    echo "Usage: $0 <container_prefix> <container_count>"
    echo "用法: $0 <容器前缀> <容器数量>"
    exit 1
  fi
  if [ $((20000 + $2)) -gt 65535 ] || [ $((30000 + $2 * 24)) -gt 65535 ]; then
    echo "Error: generated SSH or NAT port range exceeds 65535."
    echo "错误：生成的 SSH 或 NAT 端口范围超过 65535。"
    exit 1
  fi
}

replace_proxy_device() {
  local device_name="$1"
  shift
  lxc config device remove "$name" "$device_name" 2>/dev/null || true
  lxc config device add "$name" "$device_name" proxy "$@"
}

download_host_file() {
  local url="$1"
  local output="$2"
  if ! curl -fsSLk "$url" -o "$output"; then
    echo "Failed to download: $url"
    echo "下载失败：$url"
    exit 1
  fi
}

main() {
validate_inputs "$1" "$2"
check_china
storage_pool="$(lxd_storage_pool)"
if ! lxc storage show "$storage_pool" >/dev/null 2>&1; then
  echo "存储池不可用：$storage_pool" >&2
  exit 1
fi
if lxc_instance_exists "$1"; then
  echo "基础容器已存在，未修改既有实例：$1" >&2
  exit 1
fi
if ! begin_batch; then
  echo "无法创建批量日志暂存文件" >&2
  exit 1
fi
if lxc init opsmaru:debian/12 "$1" -c limits.cpu=1 -c limits.memory=256MiB -s "$storage_pool"; then
  track_batch_instance "$1"
else
  init_status=$?
  lxc_instance_exists "$1" && track_batch_instance "$1"
  echo "基础容器创建失败，已停止后续配置" >&2
  return "$init_status"
fi
# 硬盘大小
if [ -f /usr/local/bin/lxd_storage_type ]; then
  storage_type=$(cat /usr/local/bin/lxd_storage_type)
else
  storage_type="btrfs"
fi
lxc storage create "$1" "$storage_type" size=1GB >/dev/null 2>&1
lxc config device override "$1" root size=1GB || return 1
lxc config device set "$1" root limits.max 1GB || return 1
# IO
lxc config device set "$1" root limits.read 500MB || return 1
lxc config device set "$1" root limits.write 500MB || return 1
lxc config device set "$1" root limits.read 5000iops || return 1
lxc config device set "$1" root limits.write 5000iops || return 1
# 网速
lxc config device override "$1" eth0 limits.egress=300Mbit \
  limits.ingress=300Mbit \
  limits.max=300Mbit || return 1
# cpu
lxc config set "$1" limits.cpu.priority 0 || return 1
lxc config set "$1" limits.cpu.allowance 50% || return 1
lxc config set "$1" limits.cpu.allowance 25ms/100ms || return 1
# 内存
lxc config set "$1" limits.memory.swap true || return 1
lxc config set "$1" limits.memory.swap.priority 1 || return 1
# 支持docker虚拟化
lxc config set "$1" security.nesting true || return 1
# 安全性防范设置 - 只有Ubuntu支持
# if [ "$(uname -a | grep -i ubuntu)" ]; then
#   # Set the security settings
#   lxc config set "$1" security.syscalls.intercept.mknod true
#   lxc config set "$1" security.syscalls.intercept.setxattr true
# fi
# 屏蔽端口
detect_firewall_backend
blocked_ports=(3389 8888 54321 65432)
if [ "$FW_BACKEND" = "nft" ]; then
  nft list table inet lxd_block >/dev/null 2>&1 || nft add table inet lxd_block
  nft flush chain inet lxd_block forward_block 2>/dev/null
  nft list chain inet lxd_block forward_block >/dev/null 2>&1 || \
      nft 'add chain inet lxd_block forward_block { type filter hook forward priority 0; policy accept; }'
  for port in "${blocked_ports[@]}"; do
    nft add rule inet lxd_block forward_block oifname "eth0" tcp dport "$port" drop
    nft add rule inet lxd_block forward_block oifname "eth0" udp dport "$port" drop
  done
else
  for port in "${blocked_ports[@]}"; do
    iptables -C FORWARD -o eth0 -p tcp --dport "$port" -j DROP 2>/dev/null || \
        iptables -I FORWARD -o eth0 -p tcp --dport "$port" -j DROP
    iptables -C FORWARD -o eth0 -p udp --dport "$port" -j DROP 2>/dev/null || \
        iptables -I FORWARD -o eth0 -p udp --dport "$port" -j DROP
  done
fi
save_firewall_rules
if [ ! -f /usr/local/bin/ssh_bash.sh ]; then
  download_host_file https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_bash.sh /usr/local/bin/ssh_bash.sh
  chmod 777 /usr/local/bin/ssh_bash.sh || return 1
  dos2unix /usr/local/bin/ssh_bash.sh || return 1
fi
cp /usr/local/bin/ssh_bash.sh /root || return 1
if [ ! -f /usr/local/bin/config.sh ]; then
  download_host_file https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/config.sh /usr/local/bin/config.sh
  chmod 777 /usr/local/bin/config.sh || return 1
  dos2unix /usr/local/bin/config.sh || return 1
fi
cp /usr/local/bin/config.sh /root || return 1
# 批量创建容器
for ((a = 1; a <= "$2"; a++)); do
  name="$1"$a
  if lxc_instance_exists "$name"; then
    echo "容器已存在，未修改既有实例：$name" >&2
    exit 1
  fi
  if lxc copy "$1" "$name"; then
    track_batch_instance "$name"
  else
    copy_status=$?
    lxc_instance_exists "$name" && track_batch_instance "$name"
    echo "容器复制失败：${name}，已停止后续创建" >&2
    return "$copy_status"
  fi
  # 容器SSH端口 20000起  外网nat端口 30000起 每个24个端口
  sshn=$((20000 + a))
  nat1=$((30000 + (a - 1) * 24 + 1))
  nat2=$((30000 + a * 24))
  ori=$(date | md5sum)
  passwd=${ori:2:9}
  if ! lxc start "$name"; then
    echo "容器启动失败：$name" >&2
    exit 1
  fi
  sleep 1
  echo "Waiting for the container to start. Attempting to retrieve the container's IP address..."
  max_retries=3
  delay=5
  container_ip=""
  for ((i=1; i<=max_retries; i++)); do
      echo "Attempt $i: Waiting $delay seconds before retrieving container info..."
      sleep $delay
      container_ip=$(lxc list "$name" --format json | jq -r '.[0].state.network.eth0.addresses[]? | select(.family=="inet") | .address')
      if [[ -n "$container_ip" ]]; then
          echo "Container IPv4 address: $container_ip"
          break
      fi
      delay=$((delay * 2))
  done
  if [[ -z "$container_ip" ]]; then
      echo "Error: Container failed to start or no IP address was assigned."
      exit 1
  fi
  ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p' | cut -d/ -f1)
  echo "Host IPv4 address: $ipv4_address"
  # 容器始终为 debian/12，使用 apt-get
  if [[ "${CN}" == true ]]; then
    lxc exec "$name" -- apt-get update -y || return 1
    lxc exec "$name" -- apt-get install curl -y --fix-missing || return 1
    lxc exec "$name" -- curl -lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh || return 1
    lxc exec "$name" -- chmod 777 ChangeMirrors.sh || return 1
    lxc exec "$name" -- ./ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --backup true --updata-software false --clean-cache false --ignore-backup-tips || return 1
    lxc exec "$name" -- rm -f -- ChangeMirrors.sh || return 1
  fi
  lxc exec "$name" -- sudo apt-get update -y || return 1
  lxc exec "$name" -- sudo apt-get install curl -y --fix-missing || return 1
  lxc exec "$name" -- sudo apt-get install -y --fix-missing dos2unix || return 1
  lxc file push /root/ssh_bash.sh "$name"/root/ || return 1
  lxc exec "$name" -- chmod 777 ssh_bash.sh || return 1
  lxc exec "$name" -- dos2unix ssh_bash.sh || return 1
  lxc exec "$name" -- sudo ./ssh_bash.sh "$passwd" || return 1
  lxc file push /root/config.sh "$name"/root/ || return 1
  lxc exec "$name" -- chmod +x config.sh || return 1
  lxc exec "$name" -- dos2unix config.sh || return 1
  lxc exec "$name" -- bash config.sh || return 1
  if ! lxc config device override "$name" eth0 ipv4.address="$container_ip" 2>/dev/null; then
      if ! lxc config device set "$name" eth0 ipv4.address "$container_ip" 2>/dev/null; then
          echo "Error: Failed to set ipv4.address for device 'eth0' in container '$name'." >&2
          exit 1
      fi
  fi
  replace_proxy_device ssh-port "listen=tcp:$ipv4_address:$sshn" connect=tcp:0.0.0.0:22 nat=true || return 1
  if [ "$nat1" != "0" ] && [ "$nat2" != "0" ]; then
    replace_proxy_device nattcp-ports "listen=tcp:$ipv4_address:$nat1-$nat2" "connect=tcp:0.0.0.0:$nat1-$nat2" nat=true || return 1
    replace_proxy_device natudp-ports "listen=udp:$ipv4_address:$nat1-$nat2" "connect=udp:0.0.0.0:$nat1-$nat2" nat=true || return 1
  fi
  lxc config set "$name" user.description "$name $sshn $passwd $nat1 $nat2" || return 1
  printf '%s\n' "$name $sshn $passwd $nat1 $nat2" >>"$batch_pending_log" || exit 1
done
if ! commit_batch_log; then
  echo "成功日志提交失败，正在回滚本批次容器" >&2
  exit 1
fi
rm -f -- ssh_bash.sh config.sh ssh_sh.sh
}

if [ "${ONECLICKVIRT_TESTING:-}" != "1" ]; then
  main "${1:-}" "${2:-}"
fi
