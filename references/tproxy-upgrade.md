# TPROXY 升级手册（UDP 全透明 + IPv6 进阶方案）

默认 REDIRECT 方案稳定好用，但有两个结构性局限：**普通 UDP 流量（QUIC 之外的 UDP 应用、游戏、语音）不代理**、**IPv6 无法透明**（多数设备内核未编译 `IP6_NF_NAT`，nat 表做不了 v6 REDIRECT）。本手册把网关升级为 **TPROXY 模式**：TCP+UDP 全透明、v4+v6 双栈，这也是 box_for_magisk 等 Android 透明代理 Magisk 模块的推荐路线。

> 本方案经完整的桌面研究与内核能力实测形成（研究报告沉淀），升级前请通读「回退」一节。

## 为什么 TPROXY 是 Android 上的正解

1. **内核支持面**：Android 随身 WiFi 设备内核通常 `CONFIG_NETFILTER_XT_TARGET_TPROXY=y` + `CONFIG_NF_TPROXY_IPV4/6=y`（实测 U30 Pro B24 如此），而 `CONFIG_IP6_NF_NAT` 常未编译——TPROXY 是 v6 唯一的透明方案
2. **结构性防环**：TPROXY 规则只挂 `mangle PREROUTING -i br0`，**设备自身出站走 OUTPUT 链根本不经过拦截点**——代理进程自己的流量天然无环（REDIRECT 方案靠排除规则防环，TPROXY 靠链路结构防环）
3. **UDP 原生支持**：sing-box `tproxy` 入站 TCP+UDP 通吃（`redirect` 入站官方明确 TCP only）

## 第 0 步：内核能力检查（决定能不能上）

```bash
adb shell "su -c 'zcat /proc/config.gz 2>/dev/null | grep -E \"TPROXY|IP6_NF_NAT\"'"
# 必须有: CONFIG_NETFILTER_XT_TARGET_TPROXY=y
#         CONFIG_NETFILTER_XT_MATCH_SOCKET=y
#         CONFIG_NF_TPROXY_IPV4=y (v6 同理要 IPV6=y)
# IP6_NF_NAT is not set 没关系——tproxy 不依赖它
# 另确认: cat /proc/sys/net/ipv4/ip_forward (1)、rp_filter (0 为理想)
```

路由表与规则位检查（TPROXY 要占用独立 fwmark/表/规则优先级）：

```bash
adb shell "su -c 'ip rule show; ip route show table 100 2>/dev/null'"
# Android netd 自身用 pref 9999~32000 的 fwmark 规则；选 pref 9000（在其之前）
# fwmark 选 0x2023：避开 netd 的 0x10000 位与 0x1ffff 网络位
```

## 第 1 步：config.json 入站替换（只动 inbounds，DNS/route 结构不变）

```json
"inbounds": [
  { "type": "tproxy", "tag": "tproxy-in", "listen": "::", "listen_port": 7895 },
  { "type": "direct", "tag": "dns-in",    "listen": "::", "listen_port": 15353, "network": "udp" },
  { "type": "mixed",  "tag": "mixed-in",  "listen": "::", "listen_port": 2080 }
]
```

删除 `redirect` 入站。**DNS/route 保持默认方案的结构不动**——`sniff → hijack-dns → ip_is_private direct → geosite/geoip-cn direct → final proxy` 与 `default_domain_resolver: cn-dns` 正是防 DNS 死锁的标准结构。

## 第 2 步：部署 TPROXY 规则

使用 `assets/tproxy_rules_full.sh`（apply/remove 幂等，含 v4+v6、MSS 钳制、DNS 53 全劫持）。核心逻辑（理解用）：

```sh
MARK=0x2023; PORT=7895; TBL=100
# 策略路由：打标记的包查本地路由表，交给本机 tproxy 监听
ip rule  add fwmark $MARK table $TBL pref 9000
ip route add local default dev lo table $TBL

iptables -t mangle -N SB_DIVERT
iptables -t mangle -A SB_DIVERT -j MARK --set-mark $MARK
iptables -t mangle -A SB_DIVERT -j ACCEPT
iptables -t mangle -N SB_PRX
iptables -t mangle -A SB_PRX -p tcp -m socket --transparent -j SB_DIVERT  # 已建立连接直通
# DNS 劫持必须在私网排除之前——否则客户端发往 192.168.0.1:53 的查询漏给 dnsmasq，污染回归
iptables -t mangle -A SB_PRX -p udp --dport 53 -j TPROXY --on-port $PORT --tproxy-mark $MARK
iptables -t mangle -A SB_PRX -p tcp --dport 53 -j TPROXY --on-port $PORT --tproxy-mark $MARK
# 私网/保留段排除（127/8 10/8 172.16/12 192.168/16 169.254/16 224/4 240/4）RETURN
iptables -t mangle -A SB_PRX -p tcp -j TPROXY --on-port $PORT --tproxy-mark $MARK
iptables -t mangle -A SB_PRX -p udp -j TPROXY --on-port $PORT --tproxy-mark $MARK
iptables -t mangle -A PREROUTING -i br0 -j SB_PRX
```

**三个顺序要点**：DNS 劫持在私网排除**之前**；`-m socket --transparent` 分流在 TPROXY 之前；pref 9000 必须小于 netd 的 9999。

IPv6（可选二期）：同款逻辑换 `ip6tables` + `ip -6 rule/route`。升级前先确认 WiFi 客户端真的分到了 v6 地址（`ipconfig` 看全局 v6），没有就先不上，v6 维持 AAAA-reject 现状。

## 第 3 步：守护脚本适配

`99-singbox.sh` 里把规则脚本换成 `tproxy_rules_full.sh`，`check_rules` 改为检查 mangle 表：

```sh
check_rules() { iptables -t mangle -C PREROUTING -i br0 -j SB_PRX 2>/dev/null; }
```

（这正是"坑 3：检查的表/链必须与规则脚本一致"——REDIRECT 版查 nat/SB_RD，TPROXY 版查 mangle/SB_PRX。）

## 第 4 步：验证

```bash
# TCP 代理与直连（同默认方案的验证清单）
curl ... https://www.google.com/generate_204   # 204
curl ... https://www.taobao.com                # 200 亚秒
# UDP 真的走代理了（升级的核心收益）：
#   客户端访问一个 UDP-only 服务（如 quic 测试站/游戏加速器），在设备上看
adb shell "su -c 'grep tproxy-in /data/adb/singbox/singbox.log | tail -5'"
#   sing-box 日志应出现 udp 类型的 tproxy-in 入站连接
# DNS：nslookup 经网关返回真实 IP（同默认方案）
```

## 回退（出问题 60 秒恢复默认方案）

```bash
adb shell "su -c 'sh /data/adb/singbox/tproxy_rules_full.sh remove'"   # 摘 TPROXY 规则
# config.json 恢复 redirect 入站版本 → 重启 sing-box
adb shell "su -c 'sh /data/adb/singbox/tproxy_rules.sh'"               # 挂回 REDIRECT 规则
```

守护脚本同步换回。两个规则脚本在设备上并存互不干扰，随时可切。

## 参考

- sing-box tproxy 入站官方文档：https://sing-box.sagernet.org/configuration/inbound/tproxy/
- sing-box redirect 入站（TCP only 说明）：https://sing-box.sagernet.org/configuration/inbound/redirect/
- box_for_magisk（Android 透明代理 Magisk 模块，tproxy 路线）：https://github.com/taamarin/box_for_magisk
- Project X 透明代理原理（TPROXY/fwmark）：https://xtls.github.io/document/level-2/transparent_proxy/transparent_proxy.html
- ss-tproxy（经典 TPROXY 网关脚本）：https://github.com/zfl9/ss-tproxy
- sing-box DNS detour 循环依赖 issue #4468：https://github.com/SagerNet/sing-box/issues/4468
