# sing-box 三协议部署脚本（修正版）

基于 [tiktok11/tiktok11socks](https://github.com/tiktok11/tiktok11socks/blob/main/reality_hy2_ws.sh) 的脚本修订，提供 VLESS Reality、Hysteria2 和 VMess WebSocket + Cloudflare Quick Tunnel。

## 新主机安装

适用于使用 systemd 的 Linux 主机，以 root 运行。优先使用 Debian / Ubuntu；其他发行版依赖安装分支未做完整系统安装验证。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chendeng1989/singbox-installer/main/reality_hy2_ws.sh)
```

更便于保留和检查的方式：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/chendeng1989/singbox-installer/main/reality_hy2_ws.sh -o /root/reality_hy2_ws.sh
bash -n /root/reality_hy2_ws.sh && bash /root/reality_hy2_ws.sh
```

默认端口：Reality TCP 443，Hysteria2 UDP 8443，VMess TCP 15555。云平台安全组和主机防火墙需放行 TCP 443、UDP 8443；Cloudflare 通过本机连接 15555，无需为此向公网开放 15555。需能出站访问 GitHub、Reality 握手目标和 Cloudflare；Cloudflare Tunnel 还需要可用的出站隧道连接。

## 版本与配置

- 默认固定 sing-box **1.14.4**，生成的服务端配置已通过该版本真实内核的 `check`。
- 可通过环境变量指定已验证的版本，例如 `SING_BOX_VERSION=1.14.4 bash /root/reality_hy2_ws.sh`。
- 若明确需要最新正式版，可使用 `SING_BOX_VERSION=latest`；此模式会查询 GitHub Releases 最新非预发布版本。未来版本不保证兼容。
- cloudflared 从其官方 GitHub Release 下载最新发布的二进制，执行前检查能否运行；未固定其版本。
- 安装时为每台主机重新生成 UUID、密码、Reality 密钥和自签名证书，不包含任何现有主机凭据。

## 主要修复

1. 将错误路由动作 `"action": "direct"` 改为 `"action": "route", "outbound": "direct"`。
2. 移除 cloudflared 已废弃的 `h2mux` 参数，使用 `auto`；源站地址明确为 `127.0.0.1`。
3. 将隧道日志保留在 `/root/sbox/cloudflared.log`，上次日志保留为 `.previous`。
4. 最多等待 60 秒，确认获得域名且出现隧道注册日志后再继续。域名提取不再依赖“第二条匹配行”。失败会退出并保留日志，不会复用上次域名。
5. 默认固定经过配置检查的内核版本；下载失败即停止，不覆盖原有内核；更新时先用新内核检查现有配置，通过后再替换，并保留 `.previous`。
6. 使用 `nohup` 启动隧道；停止、重建或卸载时只匹配本脚本路径的 cloudflared 进程。
7. WebSocket 路径补齐开头的 `/`，VMess 默认服务器地址直接使用隧道域名。
8. 检查 root、systemd 与依赖；新安装检查配置通过后，启用 sing-box 开机启动并检查服务运行状态。

## 安装后验收

```bash
/root/sbox/sing-box check -c /root/sbox/sbconfig_server.json
systemctl is-active sing-box
systemctl is-enabled sing-box
base64 -d /root/sbox/argo.txt.b64
echo
tail -n 30 /root/sbox/cloudflared.log
```

检查配置无错误，服务为 `active`，开机启动为 `enabled`。域名非空、日志中出现注册成功记录后，仍需用客户端实际连接测试。

重新查看节点：

```bash
bash /root/reality_hy2_ws.sh
```

选择 `3. 显示客户端配置`。若未保留本地脚本，可重新下载本仓库脚本；识别到现有安装后会显示菜单。

## 使用边界

- **Quick Tunnel 是临时隧道**，没有可用性保证，重新创建后域名会改变。此修订没有创建 cloudflared systemd 自启动服务；主机重启后，运行脚本选择 `6` 重建隧道，再选择 `3` 获取新 VMess 节点。不要把 sing-box 自启动误认为隧道也会自启动。固定域名与长期无人值守恢复应另行配置 Named Tunnel。
- 主机重启后，Reality / Hysteria2 由 sing-box 的 systemd 服务恢复；VMess 隧道需要上述操作。
- 沿用上游 Hysteria2 自签名证书方案，客户端须使用对应的自签名验证设置。完整旧版 sing-box 客户端模板只作为参考；新客户端优先导入节点链接。
- 此修订通过了脚本语法、隔离回归测试及 sing-box 1.14.4 的真实服务端配置检查；尚未在全新云主机完成整机安装及三协议公网客户端连通测试。网络、供应商限制、防火墙和客户端下载版本会影响结果。
- 节点信息、`/root/sbox/sbconfig_server.json` 和 `/root/self-cert` 包含凭据或私钥，不应提交到公开仓库。

## 本地检查

```bash
bash -n reality_hy2_ws.sh
python3 test_installer.py
```

回归测试会在临时目录中验证配置生成、下载失败保留旧内核、单条域名日志提取和失败隧道不复用旧域名，不会运行安装流程或修改 `/root/sbox`。

原始来源、获取日期和源码哈希见 `UPSTREAM.txt`。保留上游 Apache-2.0 许可证；修改记录见本文。
