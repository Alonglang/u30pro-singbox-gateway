# 排障案例库（全部来自真机实战，已脱敏）

## 诊断方法论（先看这个）

**分层计时**——curl 的分段计时是定位慢问题的第一工具：

```bash
curl -s -o /dev/null -w 'dns=%{time_namelookup}s tcp=%{time_connect}s tls=%{time_appconnect}s start=%{time_starttransfer}s total=%{time_total}s\n' https://目标站/
```

| 哪段慢 | 指向 |
|---|---|
| dns 慢 | DNS 分流问题（案例 3/4） |
| tcp 慢 | 链路阻断/节点问题 |
| tls 慢但 tcp 快 | DNS 绕路（连接前解析）或大包问题 |
| start/total 慢但 tls 快 | 传输层大包黑洞（案例 5）或服务端慢 |

**对照实验**——隔离变量：
- 设备自身直连：`adb shell "su -c 'curl ... https://目标站/'"`（设备自身流量不进 REDIRECT，是纯直连基准）
- 设备经代理链路：`curl --socks5-hostname 127.0.0.1:2080 ...`（与透明代理同路由链）
- 两者都慢 → 运营商/目标站问题（案例 7）；只有代理路径慢 → 分流/sing-box 问题

**sing-box 日志**：`/data/adb/singbox/singbox.log`，关注 `outbound/direct|trojan[proxy]: outbound connection to <IP>` 判断实际走向，`ERROR` 行看失败原因。

## 案例 1：百度能开，Google 打不开

**最常见故障，几乎总是 iptables 规则丢失**（网络切换/飞行模式/netd 重刷后规则被清）。

诊断：
```bash
adb shell "su -c 'iptables-save | grep -E \"SB_RD|to-ports 7893\"'"   # 空 = 规则没了
```
- 没有 TCP REDIRECT → 流量全部直连：国内站通、被墙站不通，与症状完全吻合
- sing-box 日志里 `redirect-in` 没有新连接记录 = 流量根本没进来

修复：`sh tproxy_rules.sh` 重挂；长期靠守护脚本 30s 保活（检查守护进程活着没：`ps -A | grep 99-singbox`）。
守护失效的经典原因：`check_rules` 检查的表/链与规则脚本不一致（如脚本写 nat 表 SB_RD，检查却查 mangle 表）——每次恒失败盲目重挂还算能跑，但若脚本结构变化就会漏挂；两者必须严格一致。

同类变体：**DNS 劫持目标端口错**（REDIRECT 到的端口上没有 sing-box 在听，如被系统 mdnsd 的 5353 抢占）。表现：能上网站的靠缓存/HTTPDNS，新域名解析失败。诊断：`netstat -lnup | grep 5353` 看端口归谁，`iptables-save | grep 15353` 确认劫持指向 = dns-in 监听端口。

## 案例 2：节点"配置全对"但客户端连不上（面板侧）

透明代理配置无任何问题时，考虑节点本身：
- **ECH 兼容性**：分享链接带 `ech=` 参数而服务端 ECH 配对失效/客户端不支持 → 连接被重置。服务端面板关闭 ECH、客户端用不带 ech 的链接即好。判断方法：用 xray/sing-box 客户端分别带/不带 ECH 参数对照连接
- **证书域名不匹配**：`openssl s_client -connect 节点:端口 -servername 域名 -verify_hostname 域名`，`Verify return code: 62 (hostname mismatch)` = 证书不是这个域名的。注意"证书目录名 ≠ 证书内容"——`openssl x509 -noout -subject -ext subjectAltName` 看证书到底是谁的
- 对照基准：在**代理服务器本机**用 xray/sing-box 客户端回环连接自己的节点（全链路排除客户端因素）

## 案例 3：国内网站变慢（首次打开多 1~2 秒）

**DNS 分流失效**：国内域名的解析走了"经代理的国外 DoH"，绕一大圈。

根因（真实踩坑）：自制/转换的 geosite json 把域名放在 `domain`（精确匹配）键下，而 v2fly geosite 的语义是后缀匹配——于是**所有子域名都不命中**国内规则，DNS 掉进 final（国外 DoH）。流量层有 geoip-cn 兜底所以网页最终能开（直连），但 DNS 层每次都绕路。

诊断：
- sing-box 日志出现 `dns: exchanged <国内域名>` 且耗时 1~2s
- `nslookup 子域名.某国内站 网关IP` 明显慢

修复：改用**官方 srs 规则集**（`SagerNet/sing-geosite` / `sing-geoip` 的 rule-set 分支，天然 domain_suffix 语义），或自查 json 中域名必须在 `domain_suffix` 数组里。个别新域名仍绕路时，在 dns.rules 显式加 `{ "domain_suffix": ["该站.com"], "server": "cn-dns" }`。

## 案例 4：某台设备"别人能上就它不行"（DNS 污染）

Windows 会**并发查询所有 DNS 服务器**（含 IPv6 DNS），谁先回用谁——v6 DNS 直连查询被抢答污染，拿到假 IP（常表现为解析出毫不相关的知名 IP 段），连接失败。

诊断：`curl -v` 看 `Trying <IP>` 是不是目标站的真实 IP；`Get-DnsClientServerAddress -AddressFamily IPv6` 看有没有 v6 DNS。

修复（设备侧根治）：内核有 ip6tables nat 表则劫持 v6 DNS（tproxy_rules.sh 已含）；没有则 sing-box `dns.rules` 首位加 `{ "query_type": ["AAAA"], "action": "reject" }`——无 v6 地址可用，客户端自动回落 v4（v4 DNS 已被劫持保护）。

## 案例 5：网页能开，但加载忽快忽慢 / 大文件龟速

**MTU 黑洞**：蜂窝网络 PMTU 可低至 ~1380（低于接口 MTU 1400），TCP 按大 MSS 发送的大段（TLS 证书、页面内容）在路径上被丢，靠重传硬扛，速度随机崩。

诊断：
```bash
# 客户端不分片 ping 探路径 MTU（逐步减小 payload 找到临界值）
# payload+28 = IP 包大小；例如 1472 fail / 1352 pass → PMTU ≈ 1380
curl -w 分段计时：tcp/tls 都快，start/total 波动大（0.2s~12s）→ 传输层问题
```
修复：`iptables -t mangle -A OUTPUT/FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300`（低于实测最小 PMTU；代价约 4% 吞吐）。已内置在 tproxy_rules.sh。

## 案例 6：只有某个网站慢，其他都正常

先做**设备直连对照**（见方法论）。设备直连同样慢 → 运营商到该站 CDN 的链路问题（真实案例：移动蜂窝→某电商自建 CDN 恒定 4~5s，而其他国内站 0.1s），代理无法也不应绕过（国内站本就直连）。这类无用户侧解法，等运营商/站点侧变化。

## 案例 7：游戏/语音等 UDP 应用连不上或不走代理

REDIRECT 方案的已知局限：sing-box `redirect` 入站**只支持 TCP**（官方文档明确），DNS 靠 53 端口劫持单独解决，但普通 UDP 流量（QUIC 之外的 UDP 应用、游戏、语音、WireGuard 等）全部直连裸奔。网页无感的原因是 QUIC 失败后浏览器自动回落 TCP。

判断：UDP 应用直连测试（不连 WiFi 直连蜂窝对比），或抓 `singbox.log` 确认只有 tcp 入站。
解决：升级 TPROXY 模式（`tproxy-upgrade.md`），TCP+UDP 全透明。

## 案例 8：设备自身断网 / ADB 管理通道断（TUN 翻车，历史教训）

**症状**：部署 sing-box TUN 入站（auto_route 甚至 strict_route）后，设备自身的出站流量（包括代理进程、系统服务、ADB over network、web 管理页）全部被 tun 吸走，管理通道断线，只能靠 USB ADB 或开机短窗口抢救。

**根因**：
1. auto_route 插入的 ip rule 抢在 Android netd fwmark 体系之前，把**所有**流量（含设备自身 OUTPUT）导进 tun
2. `route_exclude_address_set` / `route_address_set` 等排除参数**在 Android 上不可用**（仅 Linux 客户端，官方文档）
3. netd 的 fwmark 语义与 sing-box 的 mark 语义互相干扰

**结论**：随身 WiFi/路由场景（设备自身要上网+被管理）**禁用 TUN 方案**，透明代理只用 REDIRECT（默认）或 TPROXY（进阶）。

**抢救路径**（若已翻车）：USB ADB 进去 `su -c 'pkill -f sing-box'` + 删 tun 相关 service.d 自启；开机竞速窗口（boot 后数秒内）执行 `am broadcast` 或直接 adb shell 杀进程也可。

## 案例 9：重启/断网恢复后代理整体失效

- 守护进程死了（`pkill -f 99-singbox` 会连自己一起杀——匹配串出现在自己命令行里）。重启守护要分两步：先 pkill（单独一条命令），再 setsid nohup 启动
- sing-box remote 类型 rule-set 在断网时重启会**启动失败**（首次下载无缓存）→ 本方案坚持 local srs + 更新脚本（失败保持旧文件）
- 蜂窝掉线期间 sing-box 可能反复重连出站——恢复后守护自动拉正，无需干预
- **手动重启 sing-box 必须让守护认得它**（真实案例：一夜翻车 1420 次）：守护若用 `pgrep -f /data/adb/singbox/sing-box`（绝对路径）判断存活，而手动重启时用了相对路径（`cd /data/adb/singbox && ./sing-box run ...`），pgrep 匹配失败 → 守护每 30s 走"死亡分支"：摘规则 → 启动新实例（端口被旧实例占着，秒死）→ 重挂规则。每次摘除窗口（约 3 秒）内新建连接直连裸奔被墙重置，表现为 ChatGPT 等长连接站点整夜 "Reconnecting... waiting for network"、curl 偶发 exit 35。**根治：守护存活检测一律用 `pidof sing-box`（按进程名匹配，与启动路径无关）**；手动重启后盯 30 秒确认 keepalive.log 不再增长

## 案例 10：重启后网关整体失效——service.d 根本不执行（U30 Pro B24 必看）

**症状**：设备重启后 Google 彻底不通（国内站正常），sing-box、守护进程、iptables 劫持规则全部消失。部署当时一切正常，第一次重启才爆雷。

**先看故障签名**（客户端 curl 一个被墙站，几秒定位）：

| 表现 | 含义 |
|---|---|
| 秒失败（~0.1s，code 000） | 无劫持规则、流量直连裸奔被墙 RST；或规则在但 sing-box 没人监听 7893 |
| 挂起超时（10s+，code 000） | 规则在、流量进了 sing-box，但代理出站不通（节点/蜂窝问题） |
| 204 | 一切正常 |

**诊断证据链**（确认是自启失效而非规则丢失）：

```bash
adb shell "su -c 'uptime'"                                                 # 设备刚重启过
adb shell "su -c 'pidof sing-box; ps -ef | grep 99-singbox | grep -v grep'" # 全空
adb shell "su -c 'iptables -t nat -S PREROUTING | grep SB_RD'"              # 无规则
adb shell "su -c 'stat -c %y /data/adb/singbox/singbox.log'"                # 日志停在重启前
```

**根因**：U30 Pro B24 的 debug_ramdisk 精简 Magisk 只有 su 提权，没有模块/脚本基础设施——service.d、post-fs-data.d **从不执行**。判别法：`/data/adb/magisk/` 是否为空；或放一个 service.d 脚本开机 touch 时间戳文件，重启后看有没有被执行。设备上唯一可靠的开机 root 自启通道是 UFI-TOOLS App（开机以 root 拉起自身 files/ 下的 ufi_keep_alive.sh、socat、ttyd）。

**修复**：按 deployment.md「开机自启」节——把启动钩子植入 `ufi_keep_alive.sh` 后 `chattr +i` 锁定。两个关键点：
- App 每次开机用模板重写该文件，不锁 immutable 钩子会被还原（真实踩坑：首版钩子植入后一次重启即被还原）
- App 私有目录改文件用 `cat >` 原地覆写保属主；`sed -i` 会重建文件把属主变 root

## 工具坑备忘

| 坑 | 规避 |
|---|---|
| toybox sed 不支持 `0,/re/` | 复杂修改整文件重写推送，别硬 sed |
| Git Bash 的 adb push 远端路径被 MSYS 转换 | 命令前加 `MSYS_NO_PATHCONV=1`；仍失败（exit 127 无输出）时用管道法 `cat 本地 | adb shell "su -c 'cat > 远端'"` |
| 企业 Windows 禁用本机 5037 端口（adb 报 10013） | adb 服务换端口：所有命令带 `-P 5038`（或任一空闲端口） |
| 改 App 私有目录（/data/data/包名/files/）下的文件 | `cat >` 原地覆写保 inode/属主；`sed -i`/重传会重建文件把属主变 root，App 可能拒绝执行 |
| Windows Store 的 python3/python 是假别名 stub | 探测后先 `-c pass` 真跑一次再信任 |
| adb shell 单引号嵌套 | 用 `su -c 'sh -s' <<'EOF'` 传整段脚本 |
| 单点 ssl 证书错误（curl exit 35）偶发 | 可能恰逢守护重挂规则的瞬间（-F 重建链），连续测三次再定性 |
| 守护的 sing-box 存活检测 | 用 `pidof sing-box`（进程名），别用 `pgrep -f` 绝对路径——手动相对路径重启会让守护误判死亡、每 30s 摘挂规则（案例 9） |
