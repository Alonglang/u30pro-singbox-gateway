---
name: u30pro-singbox-gateway
version: "2026.10.30"
description: 在已 root 的 Android 随身 WiFi / 随身路由（如中兴 U30 Pro / MU5358，或其他 Magisk root 的安卓设备）上部署 sing-box 实现透明代理网关（科学上网路由器）的完整方案：iptables REDIRECT 透明代理、DNS 劫持分流、geosite/geoip 规则集自动更新、Magisk service.d 守护进程、MTU/MSS 调优、IPv6 泄漏防护，以及"百度能上 Google 不通""国内站变慢"等经典故障的排查。当用户提到 随身WiFi 代理/随身WiFi 科学上网/sing-box 透明代理/随身路由翻墙/U30 Pro 跑代理/安卓设备做旁路由网关/MU5358 代理/singbox redirect iptables/DNS 劫持分流 等场景时必须触发。
---

# Android sing-box 透明代理网关

把一台**已 root** 的 Android 随身 WiFi（验证设备：中兴 U30 Pro / MU5358，固件 B24 + Magisk root）变成**透明代理路由器**：连它的 WiFi 即自动科学上网，客户端零配置。基于 sing-box REDIRECT 透明代理 + DNS 劫持分流 + iptables 规则 + Magisk 开机守护，全部方案经过真机完整验证。

## 前提条件（硬性，缺一不可——先 root，再谈部署）

本方案的一切操作建立在**设备已 root** 之上：

1. **设备已解锁并刷入 Magisk**：
   - 中兴 U30 Pro（MU5358，B24 固件）：先按 `u30pro-b24-root-skill` 技能完成 TrustOS 解锁 + Magisk root（含备份与恢复流程；该技能自带的 `tools/adb.exe` 也可直接用于连接设备）。公开仓库：https://github.com/qwXZhong/u30pro-b24-root-skill
   - 其他 Android 设备：先完成对应机型的 bootloader 解锁 + Magisk 安装
2. **root 就绪验证**（三条全过才能开始部署，任何一条失败先回去解决 root）：
   ```bash
   adb shell "su -c id"                              # 期望含 uid=0(root)
   adb shell "su -c 'ls -ld /data/adb'"              # 目录存在且可写
   adb shell "su -c 'mkdir -p /data/adb/service.d'"  # ⚠ 目录可创建只证明可写，不证明开机会执行
   ```
   注意：U30 Pro B24 的 su 是 `/debug_ramdisk/su`（不在 PATH，需写全路径）；其他设备通常 `su` 即可。
   **U30 Pro B24 实测：debug_ramdisk 精简版 Magisk 只有 su，开机不执行 service.d**（坑 13）——该机型开机自启必须按 deployment.md「开机自启」节挂到 UFI-TOOLS App 钩子，否则首次重启网关全挂
3. **无 root 做不了的原因**：写 `/data/adb`、执行 iptables REDIRECT/TCPMSS（需 root 的 CAP_NET_ADMIN）、Magisk service.d 开机自启——全部需要 root。没有 root 本方案不成立，也不存在等效的免 root 透明代理替代
4. **电脑侧 adb 可用**：设备 USB 调试已开、`adb devices` 可见（Windows Git Bash 下 push 远端路径需加 `MSYS_NO_PATHCONV=1`）
5. **一个可用代理节点**：协议（trojan/vless/...）、服务器域名、端口、密码/UUID

## 方案选型（三代方案的结论，用血泪换来的）

| 方案 | 结论 | 原因 |
|---|---|---|
| **TUN + auto_route** | ❌ **Android 上禁用** | auto_route 抢在 netd 之前把**所有**流量（含设备自身出站）吸进 tun；`route_exclude_address_set` 等排除参数**在 Android 不可用**（仅 Linux 客户端）。实测后果：设备自身路由被劫持、ADB/管理通道全断，只能开机窗口抢救（详见 troubleshooting.md 案例 8） |
| **REDIRECT（nat 表）** | ✅ **默认方案（本技能主线，真机长期验证）** | 简单可靠：TCP 全代理 + DNS(53) 劫持进 sing-box。已知局限：**普通 UDP 不代理**（QUIC 靠回落 TCP 所以无感；游戏/语音 UDP 直连）；IPv6 无法透明（多数随身 WiFi 内核未编译 `IP6_NF_NAT`） |
| **TPROXY（mangle 表）** | ⭐ **进阶方案（手册见 references/tproxy-upgrade.md）** | TCP+UDP 全透明、支持 v6（`NF_TPROXY_IPV6` 通常已编译）、结构性防环（只挂 `mangle PREROUTING -i br0`，设备自身流量走 OUTPUT 天然不经过）。box_for_magisk 等 Android 透明代理模块的同款路线 |

## 架构心智模型

```
WiFi 客户端(手机/电脑) ──┐
                        │ br0 (设备默认网段，U30 Pro 为 192.168.0.0/24)
                 ┌──────▼──────────────────────────────┐
                 │ Android 随身 WiFi (Magisk root)     │
                 │ iptables nat PREROUTING:            │
                 │   udp/53 → REDIRECT 15353 (DNS劫持) │
                 │   tcp     → REDIRECT 7893  (代理)   │
                 │ mangle: TCPMSS --set-mss 1300       │
                 │ sing-box:                           │
                 │   redirect-in :7893  透明代理入口    │
                 │   dns-in      :15353 DNS 入口        │
                 │   mixed-in    :2080  手动代理/测试   │
                 │   分流: geosite-cn/geoip-cn→direct  │
                 │         其余→trojan/vless 出站(代理) │
                 │   DNS: 国内域名→cn-dns(本地)         │
                 │         其余→DoH经代理(无污染)        │
                 └──────┬──────────────────────────────┘
                        │ 蜂窝接口 (MTU 常为 1400，PMTU 可能更小)
                     互联网
```

三条关键链路：
1. **流量分流**靠域名(geosite-cn)和 IP(geoip-cn) 双层判断，国内直连、国外走代理
2. **DNS 分流**只有域名层（查询时还没有 IP），所以 geosite 规则必须正确，否则国内域名 DNS 绕国外（慢 1~2 秒，这是最常见的"变慢"根源）
3. **规则不持久**：Android 的 netd/网络切换会重刷 iptables，必须有守护进程周期性重挂

## 文件清单（assets/，全部为脱敏模板）

| 文件 | 部署位置（设备上） | 作用 |
|---|---|---|
| `config.json` | `/data/adb/singbox/config.json` | sing-box 主配置（需改节点参数） |
| `tproxy_rules.sh` | `/data/adb/singbox/tproxy_rules.sh` | iptables 规则（REDIRECT 模式·默认）：TCP REDIRECT + v4/v6 DNS 劫持 + MSS 钳制 |
| `tproxy_rules_full.sh` | `/data/adb/singbox/tproxy_rules_full.sh` | iptables 规则（**TPROXY 模式·进阶**）：TCP+UDP 全透明 + v6，见 tproxy-upgrade.md |
| `99-singbox.sh` | `/data/adb/service.d/99-singbox.sh` | 守护脚本：起进程 + 30s 规则保活 + 每周更新规则集（完整版 Magisk 开机自动执行；⚠ U30 Pro B24 精简 root 不执行 service.d，需按 deployment.md「开机自启」节挂 UFI-TOOLS App 钩子） |
| `update_geosite.sh` | `/data/adb/singbox/update_geosite.sh` | 官方 srs 规则集下载校验原子替换 |

部署/修改这些文件的操作见 `references/deployment.md`；故障排查见 `references/troubleshooting.md`（含真实案例库）。

## 快速任务路由

| 场景 | 去哪里 |
|---|---|
| 从零部署 / 重建 / 换节点 / 升级 sing-box | `references/deployment.md` |
| "连了 WiFi 百度通、Google 不通" | `references/troubleshooting.md` 案例 1 |
| 国内网站变慢 / DNS 绕路 | 案例 3、4 |
| 网页能开但大文件忽快忽慢 / 下载卡 | 案例 5（MTU 黑洞） |
| 规则总丢 / 重启后失效 | 案例 2（守护与规则保活） |
| 重启后网关彻底失效（进程/规则全没了） | 案例 10（service.d 不执行——U30 Pro B24 必看） |
| 游戏/语音等 UDP 应用不走代理 | REDIRECT 方案已知局限 → `references/tproxy-upgrade.md` |
| 想让 IPv6 也透明代理 / UDP 全代理 | 升级 TPROXY → `references/tproxy-upgrade.md` |
| 设备自身断网 / ADB 管理通道断 | 案例 8（TUN 翻车——若用了 TUN 赶紧回退） |
| 怎么验证某域名走了代理还是直连 | troubleshooting.md「诊断方法论」 |

## 必须记住的十三个坑（血泪教训速查）

1. **geosite 语义**：自制 json 若把域名放 `domain`（精确匹配）键下，所有子域名都不命中——DNS 全绕国外。用官方 `.srs` 文件（天然 `domain_suffix` 语义）根治
2. **DNS 劫持端口必须等于 dns-in 监听端口**（15353）。设备上 5353 常被系统 mdnsd 占用，劫持到它 = DNS 全灭
3. **iptables 规则会丢**（netd 重刷/飞行模式/重启），守护脚本 30 秒重挂；`check_rules` 检查的表/链必须与规则脚本实际使用的一致（nat 表 SB_RD，别查成 mangle）
4. **MTU 黑洞**：蜂窝 PMTU 实测可低至 ~1380，TLS 大包被丢→传输忽快忽慢。mangle 加 `TCPMSS --set-mss 1300`
5. **IPv6 DNS 泄漏**：Windows 多 DNS 并发抢答，v6 DNS 直连查询会被污染。内核无 ip6tables nat 表时，用 sing-box DNS 规则 `query_type: AAAA → reject` 兜底
6. **`pkill -f 脚本名` 会自杀**（匹配到自己命令行）：杀守护分两步执行，或用精确路径匹配
7. **toybox sed 不支持 `0,/re/`**；改配置复杂时整文件重写推送比 sed 可靠
8. **Git Bash 下 adb push 远端路径会被 MSYS 转换**：加 `MSYS_NO_PATHCONV=1` 前缀
9. **sing-box remote 类型 rule-set 有启动依赖**（首次下载失败起不来）——弱网设备用 local srs + 定时更新脚本更稳
10. **TUN + auto_route 在 Android 禁用**：会劫持设备自身出站（netd 冲突 + 排除参数 Android 不可用），管理通道全断（案例 8）
11. **REDIRECT 只能透明 TCP**：DNS 靠 53 端口劫持解决，但普通 UDP（QUIC/游戏/语音）不代理——需要 UDP 全代理就升级 TPROXY
12. **判断慢在哪层**：`curl -w` 的 dns/tcp/tls/starttransfer/total 分段计时 + 「设备直连 vs mixed-in 代理」对照实验，是定位一切慢问题的黄金手段
13. **Magisk service.d 在 U30 Pro B24 上不执行**：该机型的 debug_ramdisk 精简 root 只有 su，无模块/脚本基础设施（判别法：`/data/adb/magisk/` 是否为空）。开机自启唯一可靠通道是 UFI-TOOLS App 的 `ufi_keep_alive.sh`（植入钩子 + `chattr +i` 防 App 开机重写，见案例 10）；完整版 Magisk 设备不受此限

## 与其他技能的配合

- **设备 root**：前提条件见上文「前提条件」节；U30 Pro B24 的完整 root 流程在 `u30pro-b24-root-skill` 技能（公开仓库：https://github.com/qwXZhong/u30pro-b24-root-skill，未安装本地技能时可直接参考）
- **代理面板**：节点来自 xray 面板（3x-ui 等）时，面板侧问题（证书/ECH/协议）参考 `3x-ui-ops` 技能——尤其 ECH：面板开了 ECH 而客户端不兼容时表现为"节点配置全对但连不上"，首选关 ECH

## 安全提醒

- **节点信息必须向用户索取**：部署/换节点时主动询问协议、服务器域名、端口、凭据——用户未提供就追问，不要猜、不要带占位符直接部署
- 模板中所有 `<占位符>`（节点域名/端口/密码）部署时替换为真实值，**不要**把填好的文件分享出去
- sing-box 出站 `insecure: true` 会让 TLS 跳过证书校验（节点证书配置正确后建议关闭）
- 设备 SSH/ADB 调试口令保持强口令；透明代理网关等于全家流量的入口
