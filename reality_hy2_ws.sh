#!/bin/bash
# Based on https://github.com/tiktok11/tiktok11socks/blob/main/reality_hy2_ws.sh
# Local maintenance revision: 2026-10-29. See README.md for changes and limits.
# Optional: SING_BOX_VERSION=1.x.y (without v) to pin a previously tested release.
set -o pipefail
umask 077
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行此脚本。" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
  echo "此脚本需要使用 systemd 的 Linux 主机。" >&2
  exit 1
fi
fail() { echo "错误：$*" >&2; exit 1; }


# Function to print characters with delay
print_with_delay() {
    text="$1"
    delay="$2"
    for ((i = 0; i < ${#text}; i++)); do
        echo -n "${text:$i:1}"
        sleep $delay
    done
    echo
}
#notice
show_notice() {
    local message="$1"

    echo "#######################################################################################################################"
    echo "                                                                                                                       "
    echo "                                ${message}                                                                             "
    echo "                                                                                                                       "
    echo "#######################################################################################################################"
}
# Introduction animation
print_with_delay "sing-reality-hy2-box" 0.05
echo ""
echo ""
# install base
install_base(){
  local missing=0 tool
  for tool in curl jq openssl tar pgrep base64; do
    command -v "$tool" >/dev/null 2>&1 || missing=1
  done
  if (( missing )); then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y curl ca-certificates jq openssl tar procps || fail "依赖安装失败"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y curl ca-certificates jq openssl tar procps-ng || fail "依赖安装失败"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl ca-certificates jq openssl tar procps-ng || fail "依赖安装失败"
    else
      fail "请先安装 curl、jq、openssl、tar、procps、base64 和 CA 证书"
    fi
  fi
  for tool in curl jq openssl tar pgrep base64; do
    command -v "$tool" >/dev/null 2>&1 || fail "缺少依赖：$tool"
  done
}

stop_cloudflared(){
  local pid
  # Only stop this installer's binary; leave other Cloudflare tunnels alone.
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done < <(pgrep -f '^/root/sbox/cloudflared-linux tunnel( |$)' || true)
}

start_quick_tunnel(){
  local port="$1" tunnel_pid attempt domain
  local logfile=/root/sbox/cloudflared.log
  stop_cloudflared
  # Invalidate the previous hostname before starting a new Quick Tunnel.
  rm -f /root/sbox/argo.txt.b64
  if [[ -f "$logfile" ]]; then
    cp -f "$logfile" "${logfile}.previous" || fail "无法备份隧道日志"
  fi
  nohup /root/sbox/cloudflared-linux tunnel \
    --url "http://127.0.0.1:${port}" --no-autoupdate \
    --edge-ip-version auto --protocol auto \
    > "$logfile" 2>&1 < /dev/null &
  tunnel_pid=$!
  echo "$tunnel_pid" > /root/sbox/cloudflared.pid
  echo "等待 Cloudflare 分配域名并注册隧道（最多 60 秒）..."
  for ((attempt=0; attempt<60; attempt++)); do
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      tail -n 30 "$logfile" >&2
      fail "cloudflared 提前退出，日志：$logfile"
    fi
    domain=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$logfile" | head -n 1)
    if [[ -n "$domain" ]] && grep -q 'Registered tunnel connection' "$logfile"; then
      printf '%s\n' "${domain#https://}" | base64 > /root/sbox/argo.txt.b64 || fail "无法保存隧道域名"
      echo "Cloudflare 隧道已注册：$domain"
      return 0
    fi
    sleep 1
  done
  stop_cloudflared
  tail -n 30 "$logfile" >&2
  fail "隧道未在 60 秒内完成注册；日志已保留，请检查网络后重试"
}

# regenrate cloudflared argo
regenarte_cloudflared_argo(){
  local port
  port=$(jq -er '.inbounds[] | select(.tag == "vmess-in") | .listen_port' /root/sbox/sbconfig_server.json) || fail "无法读取 VMess 端口"
  start_quick_tunnel "$port"
}
# download singbox and cloudflared
download_singbox(){
  local arch version tag package_name staging candidate
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    armv7l) arch=armv7 ;;
    *) fail "不支持的处理器架构：$(uname -m)" ;;
  esac
  version="${SING_BOX_VERSION:-1.14.4}"
  if [[ "$version" != latest ]]; then
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail "SING_BOX_VERSION 格式不正确"
    tag="v${version}"
  else
    tag=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
      https://api.github.com/repos/SagerNet/sing-box/releases/latest \
      | jq -er 'select(.draft == false and .prerelease == false) | .tag_name') || fail "无法取得 sing-box 正式版版本号"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "正式版版本号异常：$tag"
    version="${tag#v}"
  fi
  echo "安装 sing-box：$tag ($arch)"
  package_name="sing-box-${version}-linux-${arch}"
  staging=$(mktemp -d) || fail "无法创建临时目录"
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
    "https://github.com/SagerNet/sing-box/releases/download/${tag}/${package_name}.tar.gz" \
    -o "$staging/archive.tar.gz"; then
    rm -rf "$staging"
    fail "sing-box 下载失败，未替换现有内核"
  fi
  if ! tar --no-same-owner -xzf "$staging/archive.tar.gz" -C "$staging"; then
    rm -rf "$staging"
    fail "sing-box 解压失败"
  fi
  candidate="$staging/$package_name/sing-box"
  if [[ ! -x "$candidate" ]] || ! "$candidate" version; then
    rm -rf "$staging"
    fail "下载的 sing-box 无法执行"
  fi
  # On upgrade, check the running server's configuration BEFORE replacing its binary.
  if [[ -f /root/sbox/sbconfig_server.json ]] && ! "$candidate" check -c /root/sbox/sbconfig_server.json; then
    rm -rf "$staging"
    fail "新内核不兼容现有配置，已保留原内核"
  fi
  if [[ -f /root/sbox/sing-box ]]; then
    cp -p /root/sbox/sing-box /root/sbox/sing-box.previous || fail "无法备份原内核"
  fi
  install -m 700 "$candidate" /root/sbox/sing-box.new || fail "内核写入失败"
  mv -f /root/sbox/sing-box.new /root/sbox/sing-box || fail "内核替换失败"
  rm -rf "$staging"
}

# download singbox and cloudflared
download_cloudflared(){
  local arch staging
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    armv7l) arch=arm ;;
    *) fail "不支持的处理器架构：$(uname -m)" ;;
  esac
  staging=$(mktemp -d) || fail "无法创建临时目录"
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
    -o "$staging/cloudflared"; then
    rm -rf "$staging"
    fail "cloudflared 下载失败"
  fi
  chmod 700 "$staging/cloudflared"
  if ! "$staging/cloudflared" --version; then
    rm -rf "$staging"
    fail "下载的 cloudflared 无法执行"
  fi
  install -m 700 "$staging/cloudflared" /root/sbox/cloudflared-linux.new || fail "cloudflared 写入失败"
  mv -f /root/sbox/cloudflared-linux.new /root/sbox/cloudflared-linux || fail "cloudflared 替换失败"
  rm -rf "$staging"
}

# client configuration
show_client_configuration() {
  # Get current listen port
  current_listen_port=$(jq -r '.inbounds[0].listen_port' /root/sbox/sbconfig_server.json)
  # Get current server name
  current_server_name=$(jq -r '.inbounds[0].tls.server_name' /root/sbox/sbconfig_server.json)
  # Get the UUID
  uuid=$(jq -r '.inbounds[0].users[0].uuid' /root/sbox/sbconfig_server.json)
  # Get the public key from the file, decoding it from base64
  public_key=$(base64 --decode /root/sbox/public.key.b64)
  # Get the short ID
  short_id=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /root/sbox/sbconfig_server.json)
  # Retrieve the server IP address
  server_ip=$(curl -s4m8 ip.sb -k) || server_ip=$(curl -s6m8 ip.sb -k)
  echo ""
  echo ""
  show_notice "Reality 客户端通用链接" 
  echo ""
  echo ""
  server_link="vless://$uuid@$server_ip:$current_listen_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$current_server_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#SING-BOX-Reality"
  echo ""
  echo ""
  echo "$server_link"
  echo ""
  echo ""
  # Print the server details
  show_notice "Reality 客户端通用参数" 
  echo ""
  echo ""
  echo "服务器ip: $server_ip"
  echo "监听端口: $current_listen_port"
  echo "UUID: $uuid"
  echo "域名SNI: $current_server_name"
  echo "Public Key: $public_key"
  echo "Short ID: $short_id"
  echo ""
  echo ""
  # Get current listen port
  hy_current_listen_port=$(jq -r '.inbounds[1].listen_port' /root/sbox/sbconfig_server.json)
  # Get current server name
  hy_current_server_name=$(openssl x509 -in /root/self-cert/cert.pem -noout -subject -nameopt RFC2253 | awk -F'=' '{print $NF}')
  # Get the password
  hy_password=$(jq -r '.inbounds[1].users[0].password' /root/sbox/sbconfig_server.json)
  # Generate the link
  
  hy2_server_link="hysteria2://$hy_password@$server_ip:$hy_current_listen_port?insecure=1&sni=$hy_current_server_name"

  show_notice "Hysteria2 客户端通用链接" 
  echo ""
  echo "官方 hysteria2通用链接格式"
  echo ""
  echo "$hy2_server_link"
  echo ""
  echo ""   
  # Print the server details
  show_notice "Hysteria2 客户端通用参数" 
  echo ""
  echo ""  
  echo "服务器ip: $server_ip"
  echo "端口号: $hy_current_listen_port"
  echo "password: $hy_password"
  echo "域名SNI: $hy_current_server_name"
  echo "跳过证书验证: True"
  echo ""
  echo ""
  show_notice "Hysteria2 客户端yaml文件" 
cat << EOF

server: $server_ip:$hy_current_listen_port

auth: $hy_password

tls:
  sni: $hy_current_server_name
  insecure: true

# 可自己修改对应带宽，不添加则默认为bbr，否则使用hy2的brutal拥塞控制
# bandwidth:
#   up: 100 mbps
#   down: 100 mbps

fastOpen: true

socks5:
  listen: 127.0.0.1:5080

EOF

  argo=$(base64 --decode /root/sbox/argo.txt.b64)
  vmess_uuid=$(jq -r '.inbounds[2].users[0].uuid' /root/sbox/sbconfig_server.json)
  ws_path=$(jq -r '.inbounds[2].transport.path' /root/sbox/sbconfig_server.json)
  show_notice "vmess ws 通用链接参数" 
  echo ""
  echo ""
  echo "以下为 VMess 链接，默认直接使用 Cloudflare 隧道域名"
  echo ""
  echo ""
  echo 'vmess://'$(echo '{"add":"'$argo'","aid":"0","host":"'$argo'","id":"'$vmess_uuid'","net":"ws","path":"'$ws_path'","port":"443","ps":"sing-box-vmess-tls","tls":"tls","type":"none","v":"2"}' | base64 -w 0)
  echo ""
  echo ""
  echo -e "端口 443 可改为 2053 2083 2087 2096 8443"
  echo ""
  echo ""
  echo 'vmess://'$(echo '{"add":"'$argo'","aid":"0","host":"'$argo'","id":"'$vmess_uuid'","net":"ws","path":"'$ws_path'","port":"80","ps":"sing-box-vmess","tls":"","type":"none","v":"2"}' | base64 -w 0)
  echo ""
  echo ""
  echo -e "端口 80 可改为 8080 8880 2052 2082 2086 2095" 
  echo ""
  echo ""
  show_notice "clash-meta配置参数"
cat << EOF

port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
ipv6: true
dns:
  enable: true
  listen: :53
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver: 
    - 223.5.5.5
    - 8.8.8.8
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.0.0.1/dns-query
    - tls://dns.google
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

proxies:        
  - name: Reality
    type: vless
    server: $server_ip
    port: $current_listen_port
    uuid: $uuid
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $current_server_name
    client-fingerprint: chrome
    reality-opts:
      public-key: $public_key
      short-id: $short_id

  - name: Hysteria2
    type: hysteria2
    server: $server_ip
    port: $hy_current_listen_port
    #  up和down均不写或为0则使用BBR流控
    # up: "30 Mbps" # 若不写单位，默认为 Mbps
    # down: "200 Mbps" # 若不写单位，默认为 Mbps
    password: $hy_password
    sni: $hy_current_server_name
    skip-cert-verify: true
    alpn:
      - h3
  - name: Vmess
    type: vmess
    server: $argo
    port: 443
    uuid: $vmess_uuid
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    client-fingerprint: chrome  
    skip-cert-verify: true
    servername: $argo
    network: ws
    ws-opts:
      path: $ws_path
      headers:
        Host: $argo

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 自动选择
      - Reality
      - Hysteria2
      - Vmess
      - DIRECT

  - name: 自动选择
    type: url-test #选出延迟最低的机场节点
    proxies:
      - Reality
      - Hysteria2
      - Vmess
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50


rules:
    - GEOIP,LAN,DIRECT
    - GEOIP,CN,DIRECT
    - MATCH,节点选择

EOF

show_notice "sing-box客户端旧版模板（新客户端优先导入前面的节点链接）"
cat << EOF
{
    "dns": {
        "servers": [
            {
                "tag": "remote",
                "address": "https://1.1.1.1/dns-query",
                "detour": "select"
            },
            {
                "tag": "local",
                "address": "https://223.5.5.5/dns-query",
                "detour": "direct"
            },
            {
                "address": "rcode://success",
                "tag": "block"
            }
        ],
        "rules": [
            {
                "outbound": [
                    "any"
                ],
                "server": "local"
            },
            {
                "disable_cache": true,
                "geosite": [
                    "category-ads-all"
                ],
                "server": "block"
            },
            {
                "clash_mode": "global",
                "server": "remote"
            },
            {
                "clash_mode": "direct",
                "server": "local"
            },
            {
                "geosite": "cn",
                "server": "local"
            }
        ],
        "strategy": "prefer_ipv4"
    },
    "inbounds": [
        {
            "type": "tun",
            "inet4_address": "172.19.0.1/30",
            "inet6_address": "2001:0470:f9da:fdfa::1/64",
            "sniff": true,
            "sniff_override_destination": true,
            "domain_strategy": "prefer_ipv4",
            "stack": "mixed",
            "strict_route": true,
            "mtu": 9000,
            "endpoint_independent_nat": true,
            "auto_route": true
        },
        {
            "type": "socks",
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "sniff": true,
            "sniff_override_destination": true,
            "domain_strategy": "prefer_ipv4",
            "listen_port": 2333,
            "users": []
        },
        {
            "type": "mixed",
            "tag": "mixed-in",
            "sniff": true,
            "sniff_override_destination": true,
            "domain_strategy": "prefer_ipv4",
            "listen": "127.0.0.1",
            "listen_port": 2334,
            "users": []
        }
    ],
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "",
      "store_selected": true
    }
  },
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "outbounds": [
    {
      "tag": "select",
      "type": "selector",
      "default": "urltest",
      "outbounds": [
        "urltest",
        "sing-box-reality",
        "sing-box-hysteria2",
        "sing-box-vmess"
      ]
    },
    {
      "type": "vless",
      "tag": "sing-box-reality",
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "server": "$server_ip",
      "server_port": $current_listen_port,
      "tls": {
        "enabled": true,
        "server_name": "$current_server_name",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$public_key",
          "short_id": "$short_id"
        }
      }
    },
    {
            "type": "hysteria2",
            "server": "$server_ip",
            "server_port": $hy_current_listen_port,
            "tag": "sing-box-hysteria2",
            
            "up_mbps": 100,
            "down_mbps": 100,
            "password": "$hy_password",
            "tls": {
                "enabled": true,
                "server_name": "$hy_current_server_name",
                "insecure": true,
                "alpn": [
                    "h3"
                ]
            }
        },
        {
            "server": "$argo",
            "server_port": 443,
            "tag": "sing-box-vmess",
            "tls": {
                "enabled": true,
                "server_name": "$argo",
                "insecure": true,
                "utls": {
                    "enabled": true,
                    "fingerprint": "chrome"
                }
            },
            "transport": {
                "headers": {
                    "Host": [
                        "$argo"
                    ]
                },
                "path": "$ws_path",
                "type": "ws"
            },
            "type": "vmess",
            "security": "auto",
            "uuid": "$vmess_uuid"
        },
    {
      "tag": "direct",
      "type": "direct"
    },
    {
      "tag": "block",
      "type": "block"
    },
    {
      "tag": "dns-out",
      "type": "dns"
    },
    {
      "tag": "urltest",
      "type": "urltest",
      "outbounds": [
        "sing-box-reality",
        "sing-box-hysteria2",
        "sing-box-vmess"
      ]
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "geosite": "category-ads-all",
        "outbound": "block"
      },
      {
        "outbound": "dns-out",
        "protocol": "dns"
      },
      {
        "clash_mode": "direct",
        "outbound": "direct"
      },
      {
        "clash_mode": "global",
        "outbound": "select"
      },
      {
        "geoip": [
          "cn",
          "private"
        ],
        "outbound": "direct"
      },
      {
        "geosite": "geolocation-!cn",
        "outbound": "select"
      },
      {
        "geosite": "cn",
        "outbound": "direct"
      }
    ],
    "geoip": {
            "download_detour": "select"
        },
    "geosite": {
            "download_detour": "select"
        },
    "final": "direct"
  }
}
EOF

}
uninstall_singbox() {
            stop_cloudflared
            echo "Uninstalling..."
          # Stop and disable sing-box service
          systemctl stop sing-box
          systemctl disable sing-box > /dev/null 2>&1

          # Remove files
          rm /etc/systemd/system/sing-box.service
          rm /root/sbox/sbconfig_server.json
          rm /root/sbox/sing-box
          rm /root/sbox/cloudflared-linux
          rm /root/sbox/argo.txt.b64
          rm /root/sbox/public.key.b64
          rm /root/self-cert/private.key
          rm /root/self-cert/cert.pem
          rm -rf /root/self-cert/
          rm -rf /root/sbox/
          echo "DONE!"
}
install_base

# Check if reality.json, sing-box, and sing-box.service already exist
if [ -f "/root/sbox/sbconfig_server.json" ] && [ -f "/root/sbox/sing-box" ] && [ -f "/root/sbox/public.key.b64" ] && [ -f "/root/sbox/argo.txt.b64" ] && [ -f "/etc/systemd/system/sing-box.service" ]; then

    echo "sing-box-reality-hysteria2已经安装"
    echo ""
    echo "请选择选项:"
    echo ""
    echo "1. 重新安装"
    echo "2. 修改配置"
    echo "3. 显示客户端配置"
    echo "4. 卸载"
    echo "5. 更新sing-box内核（正式版；可用 SING_BOX_VERSION 指定版本）"
    echo "6. 手动重启cloudflared（临时域名会改变）"
    echo ""
    read -p "Enter your choice (1-6): " choice

    case $choice in
        1)
          show_notice "Reinstalling..."
          stop_cloudflared
          # Uninstall previous installation
          systemctl stop sing-box
          systemctl disable sing-box > /dev/null 2>&1
          rm /etc/systemd/system/sing-box.service
          rm /root/sbox/sbconfig_server.json
          rm /root/sbox/sing-box
          rm /root/sbox/cloudflared-linux
          rm /root/sbox/argo.txt.b64
          rm /root/sbox/public.key.b64
          rm /root/self-cert/private.key
          rm /root/self-cert/cert.pem
          rm -rf /root/self-cert/
          rm -rf /root/sbox/
          
          # Proceed with installation
        ;;
        2)
          #Reality modify
          show_notice "开始修改reality端口和域名"
          # Get current listen port
          current_listen_port=$(jq -r '.inbounds[0].listen_port' /root/sbox/sbconfig_server.json)

          # Ask for listen port
          read -p "请输入想要修改的端口号 (当前端口为 $current_listen_port): " listen_port
          listen_port=${listen_port:-$current_listen_port}

          # Get current server name
          current_server_name=$(jq -r '.inbounds[0].tls.server_name' /root/sbox/sbconfig_server.json)

          # Ask for server name (sni)
          read -p "请输入想要使用的h2域名 (当前域名为 $current_server_name): " server_name
          server_name=${server_name:-$current_server_name}
          echo ""
          # modifying hysteria2 configuration
          show_notice "开始修改hysteria2端口"
          echo ""
          # Get current listen port
          hy_current_listen_port=$(jq -r '.inbounds[1].listen_port' /root/sbox/sbconfig_server.json)
          
          # Ask for listen port
          read -p "请属于想要修改的端口 (当前端口为 $hy_current_listen_port): " hy_listen_port
          hy_listen_port=${hy_listen_port:-$hy_current_listen_port}

          # Modify reality.json with new settings
          jq --arg listen_port "$listen_port" --arg server_name "$server_name" --arg hy_listen_port "$hy_listen_port" '.inbounds[1].listen_port = ($hy_listen_port | tonumber) | .inbounds[0].listen_port = ($listen_port | tonumber) | .inbounds[0].tls.server_name = $server_name | .inbounds[0].tls.reality.handshake.server = $server_name' /root/sbox/sbconfig_server.json > /root/sb_modified.json
          mv /root/sb_modified.json /root/sbox/sbconfig_server.json

          # Restart sing-box service
          systemctl restart sing-box
          # show client configuration
          show_client_configuration
          exit 0
        ;;
      3)  
          # show client configuration
          show_client_configuration
          exit 0
      ;;	
      4)
          uninstall_singbox
          exit 0
          ;;
      5)
          show_notice "Update Sing-box..."
          download_singbox
          # Check configuration and start the service
          if /root/sbox/sing-box check -c /root/sbox/sbconfig_server.json; then
              echo "Configuration checked successfully. Starting sing-box service..."
              systemctl daemon-reload
              systemctl enable sing-box > /dev/null 2>&1
              systemctl start sing-box
              systemctl restart sing-box
          fi
          echo ""  
          exit 1
          ;;
      6)
          regenarte_cloudflared_argo
          echo "重新启动完成，查看新的vmess客户端信息"
          show_client_configuration
          exit 1
          ;;
      *)
          echo "Invalid choice. Exiting."
          exit 1
          ;;
	esac
	fi

mkdir -p "/root/sbox/" || fail "无法创建安装目录"

download_singbox

download_cloudflared

# reality
echo "开始配置Reality"
echo ""
# Generate key pair
echo "自动生成基本参数"
echo ""
key_pair=$(/root/sbox/sing-box generate reality-keypair) || fail "Reality 密钥生成失败"
echo "Key pair生成完成"
echo ""

# Extract private key and public key
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')

# Save the public key in a file using base64 encoding
echo "$public_key" | base64 > /root/sbox/public.key.b64

# Generate necessary values
uuid=$(/root/sbox/sing-box generate uuid)
short_id=$(/root/sbox/sing-box generate rand --hex 8)
echo "uuid和短id 生成完成"
echo ""
# Ask for listen port
read -p "请输入Reality端口 (default: 443): " listen_port
listen_port=${listen_port:-443}
echo ""
# Ask for server name (sni)
read -p "请输入想要使用的域名 (default: itunes.apple.com): " server_name
server_name=${server_name:-itunes.apple.com}
echo ""
# hysteria2
echo "开始配置hysteria2"
echo ""
# Generate hysteria necessary values
hy_password=$(/root/sbox/sing-box generate rand --hex 8)

# Ask for listen port
read -p "请输入hysteria2监听端口 (default: 8443): " hy_listen_port
hy_listen_port=${hy_listen_port:-8443}
echo ""

# Ask for self-signed certificate domain
read -p "输入自签证书域名 (default: bing.com): " hy_server_name
hy_server_name=${hy_server_name:-bing.com}
mkdir -p /root/self-cert/ && openssl ecparam -genkey -name prime256v1 -out /root/self-cert/private.key && openssl req -new -x509 -days 36500 -key /root/self-cert/private.key -out /root/self-cert/cert.pem -subj "/CN=${hy_server_name}"
echo ""
echo "自签证书生成完成"
echo ""
# vmess ws
echo "开始配置vmess"
echo ""
# Generate hysteria necessary values
vmess_uuid=$(/root/sbox/sing-box generate uuid)
read -p "请输入vmess端口，默认为15555: " vmess_port
vmess_port=${vmess_port:-15555}
echo ""
read -p "ws路径 (默认随机生成): " ws_path
ws_path=${ws_path:-$(/root/sbox/sing-box generate rand --hex 6)}
ws_path="/${ws_path#/}"

start_quick_tunnel "$vmess_port"

# Retrieve the server IP address
server_ip=$(curl -s4m8 ip.sb -k) || server_ip=$(curl -s6m8 ip.sb -k)

# Create reality.json using jq
jq -n --arg listen_port "$listen_port" --arg vmess_port "$vmess_port" --arg vmess_uuid "$vmess_uuid"  --arg ws_path "$ws_path" --arg server_name "$server_name" --arg private_key "$private_key" --arg short_id "$short_id" --arg uuid "$uuid" --arg hy_listen_port "$hy_listen_port" --arg hy_password "$hy_password" --arg server_ip "$server_ip" '{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ($listen_port | tonumber),
      "users": [
        {
          "uuid": $uuid,
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": $server_name,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": $server_name,
            "server_port": 443
          },
          "private_key": $private_key,
          "short_id": [$short_id]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in", 
      "listen": "::",
      "listen_port": ($hy_listen_port | tonumber),
      "users": [
        {
          "password": $hy_password
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/root/self-cert/cert.pem",
        "key_path": "/root/self-cert/private.key"
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": ($vmess_port | tonumber),
      "users": [
        {
          "uuid": $vmess_uuid,
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": $ws_path
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": ["vless-in", "hy2-in", "vmess-in"],
        "action": "route", "outbound": "direct"
      }
    ],
    "final": "direct"
  }
}' > /root/sbox/sbconfig_server.json || fail "服务端配置生成失败"



# Create sing-box.service
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/root/sbox/sing-box run -c /root/sbox/sbconfig_server.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF


# Check configuration and start the service
if /root/sbox/sing-box check -c /root/sbox/sbconfig_server.json; then
    echo "Configuration checked successfully. Starting sing-box service..."
    systemctl daemon-reload
    systemctl enable sing-box > /dev/null 2>&1
    systemctl restart sing-box || fail "sing-box 启动失败，请查看 journalctl -u sing-box"
    systemctl is-active --quiet sing-box || fail "sing-box 未处于运行状态"

    show_client_configuration


else
    fail "配置检查失败，未启动 sing-box。请查看上方报错。"
fi
