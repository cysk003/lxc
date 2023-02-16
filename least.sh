#!/bin/bash
# by https://github.com/spiritLHLS/lxc
# cd /root
# ./least.sh NAT服务器前缀 数量
# 2023.02.16

rm -rf log
lxc init images:debian/9 "$1" -c limits.cpu=1 -c limits.memory=128MiB
lxc config device override "$1" root size=200MB
lxc config device set "$1" root limits.read 100MB
lxc config device set "$1" root limits.write 100MB
lxc config device set "$1" root limits.read 100iops
lxc config device set "$1" root limits.write 100iops
lxc config device set "$1" root limits.max 300MB
lxc config device override "$1" eth0 limits.egress=300Mbit limits.ingress=300Mbit
lxc config set "$1" limits.cpu.priority 0
lxc config set "$1" limits.cpu.allowance 50%
lxc config set "$1" limits.cpu.allowance 25ms/100ms
lxc config set "$1" limits.memory.swap true
lxc config set "$1" limits.memory.swap.priority 1
lxc config set "$1" security.nesting true
# if [ "$(uname -a | grep -i ubuntu)" ]; then
#   # Set the security settings
#   lxc config set "$1" security.syscalls.intercept.mknod true
#   lxc config set "$1" security.syscalls.intercept.setxattr true
# fi
# 屏蔽端口
blocked_ports=( 20 21 22 23 25 53 67 68 69 110 139 143 161 389 443 1433 1521 2094 3306 3389 5000 5432 5632 5900 6379 7001 8888 9200 10000 27017 22122 54321 65432 )
# 批量创建容器
for ((a=1;a<="$2";a++)); do
  lxc copy "$1" "$1"$a
  name="$1"$a
  sshn=$(( 20000 + a ))
  ori=$(date | md5sum)
  passwd=${ori: 2: 9}
  lxc start "$1"$a
  sleep 1
  lxc exec "$1"$a -- apt update -y
  lxc exec "$1"$a -- sudo dpkg --configure -a
  lxc exec "$1"$a -- sudo apt-get update
  lxc exec "$1"$a -- sudo apt-get install dos2unix curl wget -y
  lxc exec "$1"$a -- curl -L https://raw.githubusercontent.com/spiritLHLS/lxc/main/ssh.sh -o ssh.sh
  lxc exec "$1"$a -- chmod 777 ssh.sh
  lxc exec "$1"$a -- dos2unix ssh.sh
  lxc exec "$1"$a -- sudo ./ssh.sh $passwd
  lxc exec "$1"$a -- curl -L https://github.com/spiritLHLS/lxc/raw/main/config.sh -o config.sh 
  lxc exec "$1"$a -- chmod +x config.sh
  lxc exec "$1"$a -- bash config.sh
  container_name="$1"$a
  container_ip_address=$(lxc list ${container_name} -c 4 | awk 'NR==4 {print $2}')
  for port in "${blocked_ports[@]}"; do
    iptables -A OUTPUT -s ${container_ip_address} -d 0.0.0.0/0 -p tcp --dport ${port} -j DROP
    iptables -A OUTPUT -s ${container_ip_address} -d 0.0.0.0/0 -p udp --dport ${port} -j DROP
    iptables -A INPUT -d ${container_ip_address} -s 0.0.0.0/0 -p tcp --sport ${port} -j DROP
    iptables -A INPUT -d ${container_ip_address} -s 0.0.0.0/0 -p udp --sport ${port} -j DROP
  done
  lxc config device add "$1"$a ssh-port proxy listen=tcp:0.0.0.0:$sshn connect=tcp:127.0.0.1:22
  echo "$name $sshn $passwd" >> log
done
