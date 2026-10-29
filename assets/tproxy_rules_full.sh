#!/system/bin/sh
# TPROXY 模式规则（进阶方案：TCP+UDP 全透明 + v6 可选，配合 tproxy 入站 7895）
# 与 tproxy_rules.sh（REDIRECT 模式）互斥使用；两者可共存于设备，切换前先 remove 对方
#
# 结构要点：
#  - 只挂 mangle PREROUTING -i <LAN_IF>：设备自身流量走 OUTPUT 链，天然防环
#  - DNS 53 劫持置于私网排除之前（否则发往网关:53 的查询漏给 dnsmasq，污染回归）
#  - fwmark 0x2023 避开 netd 的 0x10000/0x1ffff；pref 9000 小于 netd 的 9999
#  - 幂等：-C 检查后才 -A；remove 做完整逆操作
#
# 用法: sh tproxy_rules_full.sh [remove]

MARK=0x2023
PORT=7895          # sing-box tproxy 入站端口
TBL=100            # 独立策略路由表（部署前确认空闲: ip route show table 100）
LAN_IF=br0         # WiFi 桥接口
LAN_NET=192.168.0.0/24   # 设备 LAN 网段（按实际修改）
V6=1               # 1=同时挂 v6（客户端有全局 v6 地址才有意义；没有设 0）

apply_rules() {
    # 策略路由：带 mark 的包走本地表，交给本机 tproxy 监听
    ip rule show | grep -q "fwmark 0x2023 lookup $TBL" || ip rule add fwmark $MARK table $TBL pref 9000
    ip route show table $TBL 2>/dev/null | grep -q local || ip route add local default dev lo table $TBL

    iptables -t mangle -N SB_DIVERT 2>/dev/null
    iptables -t mangle -F SB_DIVERT
    iptables -t mangle -A SB_DIVERT -j MARK --set-mark $MARK
    iptables -t mangle -A SB_DIVERT -j ACCEPT

    iptables -t mangle -N SB_PRX 2>/dev/null
    iptables -t mangle -F SB_PRX
    # 已建立的透明 socket 直通
    iptables -t mangle -A SB_PRX -p tcp -m socket --transparent -j SB_DIVERT 2>/dev/null
    iptables -t mangle -A SB_PRX -p udp -m socket --transparent -j SB_DIVERT 2>/dev/null
    # DNS 全劫持（必须在私网排除之前！）
    iptables -t mangle -A SB_PRX -p udp --dport 53 -j TPROXY --on-port $PORT --tproxy-mark $MARK
    iptables -t mangle -A SB_PRX -p tcp --dport 53 -j TPROXY --on-port $PORT --tproxy-mark $MARK
    # 私网/保留段排除（本网段管理服务直通）
    for net in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 $LAN_NET 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4; do
        iptables -t mangle -A SB_PRX -d $net -j RETURN
    done
    # 其余 TCP/UDP 全透明代理
    iptables -t mangle -A SB_PRX -p tcp -j TPROXY --on-port $PORT --tproxy-mark $MARK
    iptables -t mangle -A SB_PRX -p udp -j TPROXY --on-port $PORT --tproxy-mark $MARK
    iptables -t mangle -C PREROUTING -i $LAN_IF -j SB_PRX 2>/dev/null || \
        iptables -t mangle -A PREROUTING -i $LAN_IF -j SB_PRX

    # MSS 钳制（蜂窝 PMTU 黑洞防护，同 REDIRECT 方案）
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300

    if [ "$V6" = "1" ]; then
        # v6 同款（内核需 NF_TPROXY_IPV6=y；失败自动忽略）
        ip -6 rule show | grep -q "fwmark 0x2023 lookup $TBL" || ip -6 rule add fwmark $MARK table $TBL pref 9000 2>/dev/null
        ip -6 route show table $TBL 2>/dev/null | grep -q local || ip -6 route add local default dev lo table $TBL 2>/dev/null
        ip6tables -t mangle -N SB_DIVERT 2>/dev/null
        ip6tables -t mangle -F SB_DIVERT 2>/dev/null
        ip6tables -t mangle -A SB_DIVERT -j MARK --set-mark $MARK 2>/dev/null
        ip6tables -t mangle -A SB_DIVERT -j ACCEPT 2>/dev/null
        ip6tables -t mangle -N SB_PRX6 2>/dev/null
        ip6tables -t mangle -F SB_PRX6 2>/dev/null
        ip6tables -t mangle -A SB_PRX6 -p tcp -m socket --transparent -j SB_DIVERT 2>/dev/null
        ip6tables -t mangle -A SB_PRX6 -p udp --dport 53 -j TPROXY --on-port $PORT --tproxy-mark $MARK 2>/dev/null
        ip6tables -t mangle -A SB_PRX6 -p tcp --dport 53 -j TPROXY --on-port $PORT --tproxy-mark $MARK 2>/dev/null
        for net in fc00::/7 fe80::/10 ff00::/8; do
            ip6tables -t mangle -A SB_PRX6 -d $net -j RETURN 2>/dev/null
        done
        ip6tables -t mangle -A SB_PRX6 -p tcp -j TPROXY --on-port $PORT --tproxy-mark $MARK 2>/dev/null
        ip6tables -t mangle -A SB_PRX6 -p udp -j TPROXY --on-port $PORT --tproxy-mark $MARK 2>/dev/null
        ip6tables -t mangle -C PREROUTING -i $LAN_IF -j SB_PRX6 2>/dev/null || \
            ip6tables -t mangle -A PREROUTING -i $LAN_IF -j SB_PRX6 2>/dev/null
    fi
    echo "TPROXY rules applied (v4 tcp+udp+dns${V6:+ +v6})"
}

remove_rules() {
    iptables -t mangle -D PREROUTING -i $LAN_IF -j SB_PRX 2>/dev/null
    iptables -t mangle -F SB_PRX 2>/dev/null;  iptables -t mangle -X SB_PRX 2>/dev/null
    iptables -t mangle -F SB_DIVERT 2>/dev/null; iptables -t mangle -X SB_DIVERT 2>/dev/null
    ip6tables -t mangle -D PREROUTING -i $LAN_IF -j SB_PRX6 2>/dev/null
    ip6tables -t mangle -F SB_PRX6 2>/dev/null; ip6tables -t mangle -X SB_PRX6 2>/dev/null
    ip6tables -t mangle -F SB_DIVERT 2>/dev/null; ip6tables -t mangle -X SB_DIVERT 2>/dev/null
    ip rule del fwmark $MARK table $TBL pref 9000 2>/dev/null
    ip route flush table $TBL 2>/dev/null
    ip -6 rule del fwmark $MARK table $TBL pref 9000 2>/dev/null
    echo "TPROXY rules removed (fail-open 直连)"
}

case "$1" in
    remove) remove_rules ;;
    *) apply_rules ;;
esac
