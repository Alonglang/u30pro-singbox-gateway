# 部署手册（从零搭建透明代理网关）

> 本手册部署的是 **REDIRECT 模式**（默认主线，真机长期验证）。需要 UDP 全透明/IPv6 透明时，按 `tproxy-upgrade.md` 升级为 TPROXY 模式。**无论哪种模式，都不要用 TUN + auto_route**（Android 上会劫持设备自身流量导致管理通道断线，见 troubleshooting.md 案例 8）。

## 设备网络架构参考（U30 Pro B24 实测，其他设备先探测再对号入座）

| 项目 | 实况 | 对部署的意义 |
|---|---|---|
| LAN | `br0` = 192.168.0.1/24（wlan0 AP + usb0 RNDIS 桥接）；DHCP 由 networkstack 提供，DNS 下发 192.168.0.1 | 规则挂 `-i br0`；排除 `$LAN_NET` 保住管理服务 |
| WAN | `sipa_eth0`（移动 CGNAT），MTU 1400，实际 PMTU 可低至 ~1380 | MSS 钳制 1300 的依据 |
| 路由体系 | Android netd fwmark 多表（规则 pref 9999~32000） | TPROXY 用 pref 9000/fwmark 0x2023 避开；iptables 规则会被 netd 重刷 → 守护保活 |
| IPv6 | br0/WAN 均可能有 GUA；dnsmasq 监听 v6 :53 | 客户端可能拿 v6 → DNS 泄漏风险（AAAA-reject 兜底 / TPROXY v6 根治） |
| 管理通道 | ADB 走独立 USB function；web/ttyd 监听 br0 | ADB 不经 br0 规则，是翻车时的救命通道 |
| root | `/debug_ramdisk/su -c`（su 不在 PATH） | 所有命令用它提权 |

探测命令：`ip addr show`、`ip route show`、`ip rule show`、`ip route show table 100`（确认空闲）。

## 前置条件（按顺序逐项确认，全部通过再往下走）

### ① 设备已 root —— 硬前提，本方案完全建立在它之上

本方案的每一步都依赖 root：写 `/data/adb`、执行 iptables REDIRECT/TCPMSS（需 CAP_NET_ADMIN）、Magisk `service.d` 开机自启。**未 root 的设备此方案不可行，也没有免 root 的等效替代**。

root 获取（按机型，这是独立的前置工程，不在本技能范围内）：
- **中兴 U30 Pro（MU5358，B24 固件）**：按 `u30pro-b24-root-skill` 技能完成 TrustOS 解锁 + Magisk root（该流程含完整备份与恢复；建议 root 后先稳定使用一段时间再叠加本方案）
- **其他 Android 设备**：先完成对应机型的 bootloader 解锁 + Magisk 安装，确认 Magisk 管理器能正常授权

root 就绪验证（三条全过才算过）：

```bash
adb shell "su -c id"                              # 期望输出含 uid=0(root)
adb shell "su -c 'ls -ld /data/adb'"              # 目录存在（drwxrwxrwx root root）
adb shell "su -c 'mkdir -p /data/adb/service.d && echo OK'"   # Magisk 自启目录可用
```

说明：U30 Pro B24 的 su 在 `/debug_ramdisk/su`（不在 PATH，示例中把 `su` 换成该全路径）；一般设备 `su` 即可。首次执行 su 时设备上会弹 Magisk 授权框，需点允许。

### ② 电脑侧 adb

- 设备开发者选项 → USB 调试已开启，USB 连接后 `adb devices` 能看到设备
- Windows Git Bash 下 push 远端路径要加 `MSYS_NO_PATHCONV=1` 防止路径被 MSYS 转换
- 没有 adb 的环境：U30 Pro 技能自带免安装 `tools/adb.exe` 可直接用

### ③ 一个可用的代理节点

- 协议（trojan/vless/...）、服务器域名、端口、密码/UUID
- 节点本身要先在普通客户端（手机/电脑代理 App）上验证可用，再拿来做网关——否则排障时分不清是网关问题还是节点问题
- 节点来自 xray 面板时，面板侧注意事项（证书匹配、ECH 兼容性）见 `3x-ui-ops` 技能

### ④ sing-box arm64 二进制

从 https://github.com/SagerNet/sing-box/releases 下载 android-arm64 版（可电脑下载后 push，或设备经已有代理下载）。

## 目录与文件布局

```
/data/adb/singbox/            # 主目录
├── sing-box                  # 二进制 (chmod +x)
├── config.json               # 主配置（assets/config.json 模板改占位符）
├── tproxy_rules.sh           # iptables 规则脚本
├── update_geosite.sh         # 规则集更新脚本
├── geosite-cn.srs            # 官方规则集（部署时下载，见步骤 3）
├── geoip-cn.srs
└── singbox.log               # 运行日志
/data/adb/service.d/99-singbox.sh   # Magisk 开机守护（assets/99-singbox.sh）
```

## 部署步骤

### 1. 放置文件

```bash
adb shell "su -c 'mkdir -p /data/adb/singbox'"
# 逐个 push（Git Bash 加 MSYS_NO_PATHCONV=1），再 su cp 到位并 chmod +x
MSYS_NO_PATHCONV=1 adb push config.json /data/local/tmp/
adb shell "su -c 'cp /data/local/tmp/config.json /data/adb/singbox/; chmod 644 /data/adb/singbox/config.json'"
# tproxy_rules.sh / update_geosite.sh / 99-singbox.sh 同理；sh 文件 chmod +x
# 99-singbox.sh 放 /data/adb/service.d/（Magisk service.d 开机自动执行）
```

### 2. 获取节点信息并替换 config.json 占位符

**AI 执行时必须先向用户询问节点信息**（协议 / 服务器域名 / 端口 / 密码或 UUID；用户没给就不要猜，也不要用占位符直接部署），拿到后替换三处：`<PROXY_SERVER>`（3 处：DNS 规则、outbound server、tls.server_name）、`<PROXY_PORT>`、`<PROXY_PASSWORD>`。
按需检查：LAN 网段/接口名（在 tproxy_rules.sh 里，用户设备不是默认值时询问或探测 `ip addr`）；节点协议非 trojan 时替换 `outbounds[0]`（vless 的 password→uuid，加 encryption:"none"）。

**证书建议**：节点用有效证书（ACME 签发）保持 `insecure: false`。仅当节点证书自签/临时不可信才改 true，事后关掉。

### 3. 下载官方规则集（首次）

```bash
adb shell "su -c 'cd /data/adb/singbox && \
  curl -s -m 60 -o geosite-cn.srs https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs && \
  curl -s -m 60 -o geoip-cn.srs https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs && \
  ls -la *.srs'"
# 校验：两个文件都应为 3万+ 字节且 head -c 3 为 "SRS"
# 注意 geoip 在 sing-geoip 仓库（不是 sing-geosite），404 多半是下错了仓库
# 设备直连 GitHub 不通时：先启动一次 sing-box（流量会直连出去），再用
#   curl --socks5-hostname 127.0.0.1:2080 ...  经 mixed 入站下载
```

### 4. 语法检查并启动

```bash
adb shell "su -c 'cd /data/adb/singbox && ./sing-box check -c config.json && \
  nohup ./sing-box run -D . -c config.json >> singbox.log 2>&1 &'"
sleep 3
adb shell "su -c 'pgrep -f sing-box && echo RUNNING; tail -5 /data/adb/singbox/singbox.log'"
```

### 5. 挂规则并启动守护

```bash
adb shell "su -c 'sh /data/adb/singbox/tproxy_rules.sh'"
# 启动守护（重启设备后 Magisk 会自动跑 service.d，无需手动）
adb shell "su -c 'setsid nohup sh /data/adb/service.d/99-singbox.sh >/dev/null 2>&1 < /dev/null &'"
```

### 6. 验证清单（全部通过才算部署成功）

在**连着该设备 WiFi 的客户端电脑**上：

```bash
# ① DNS 劫持生效：返回真实 IP（对被墙域名尤其重要）
nslookup www.google.com <设备网关IP>        # 应返回 Google 真实 IP 段，不是假 IP
# ② AAAA 被拒（v6 泄漏防护）
nslookup -type=AAAA www.google.com <网关IP> # 应返回 Query refused / 空
# ③ 国外走代理
curl -s -o /dev/null -w '%{http_code}' https://www.google.com/generate_204   # 204
# ④ 国内直连且快
curl -s -o /dev/null -w '%{http_code} %{time_total}s' https://www.taobao.com # 200, 亚秒
# ⑤ MTU 健康（大页传输不卡）
curl -s -o /dev/null -w '%{time_total}s' https://www.jd.com                  # 波动应 <1s
```

设备侧验证（不依赖客户端）：

```bash
adb shell "su -c 'curl -s --socks5-hostname 127.0.0.1:2080 -o /dev/null \
  -w \"%{http_code} %{time_total}s\" https://www.google.com/generate_204'"
# mixed-in 2080 走的是与透明代理完全相同的路由链路，是设备上最可靠的全路径测试手段
adb shell "su -c 'iptables-save | grep -E \"SB_RD|to-ports\"'"   # 规则在
adb shell "su -c 'grep -E \"ERROR|outbound/trojan|outbound/vless\" /data/adb/singbox/singbox.log | tail -10'"
```

## 日常运维

| 操作 | 命令 |
|---|---|
| 看日志 | `adb shell "su -c 'tail -50 /data/adb/singbox/singbox.log'"` |
| 重启 sing-box | `su -c 'pkill -f singbox/sing-box'`（守护 30s 内自动拉起） |
| 立即更新规则集 | `su -c 'sh /data/adb/singbox/update_geosite.sh'` |
| 临时关闭代理(直连保底) | `su -c 'sh /data/adb/singbox/tproxy_rules.sh remove'` |
| 换节点 | 改 config.json 占位符 → `sing-box check` → 重启进程 |

## 升级 sing-box 二进制

电脑下载新版 arm64 包 → push → 替换 `/data/adb/singbox/sing-box` → `chmod +x` → 杀进程由守护拉起。配置格式大版本变更时先 `sing-box check` 验证。
