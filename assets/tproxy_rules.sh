#!/system/bin/sh
# 透明代理 iptables 规则（透明网关核心）
# v4: TCP REDIRECT 到 sing-box + DNS 劫持到 sing-box
# v6: DNS 劫持（部分设备内核无 ip6tables nat 表，失败自动忽略——
#     此时 IPv6 DNS 泄漏由 sing-box 的 AAAA-reject 规则兜底）
# MSS: 蜂窝网络 PMTU 常小于 1500，钳制 MSS 防大包黑洞
#
# 用法: sh tproxy_rules.sh          # 应用规则
#       sh tproxy_rules.sh remove   # 摘除规则（直连保底）

PORT=7893        # sing-box redirect 入站端口
DNSPORT=15353    # sing-box dns-in 端口
LAN_IF=br0       # WiFi 桥接口（多数安卓路由设备为 br0，按实际 ip link 修改）
LAN_NET=192.168.0.0/24  # 设备 LAN 网段（U30 Pro 默认，按实际修改）

apply_rules() {
    iptables -t nat -N SB_RD 2>/dev/null
    iptables -t nat -F SB_RD
    iptables -t nat -A SB_RD -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A SB_RD -d $LAN_NET -j RETURN
    iptables -t nat -A SB_RD -p tcp -j REDIRECT --to-ports $PORT
    iptables -t nat -C PREROUTING -i $LAN_IF -p tcp -j SB_RD 2>/dev/null || \
        iptables -t nat -A PREROUTING -i $LAN_IF -p tcp -j SB_RD

    # DNS 劫持：WiFi 客户端 DNS 全部交给 sing-box（国外域名经代理 DoH，无污染）
    iptables -t nat -C PREROUTING -i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports $DNSPORT 2>/dev/null || \
        iptables -t nat -A PREROUTING -i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports $DNSPORT

    # v6 DNS 劫持（内核无 nat 表时忽略）
    ip6tables -t nat -C PREROUTING -i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports $DNSPORT 2>/dev/null || \
        ip6tables -t nat -A PREROUTING -i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports $DNSPORT 2>/dev/null

    # MSS 钳制：防蜂窝 PMTU 黑洞（大包被丢→传输忽快忽慢）
    iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300

    echo "rules applied (v4 TCP+v4 DNS+v6 DNS(best-effort)+MSS)"
}

remove_rules() {
    iptables -t nat -D PREROUTING -i $LAN_IF -p tcp -j SB_RD 2>/dev/null
    iptables -t nat -D PREROUTING -i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports $DNSPORT 2>/dev/null
    iptables -t nat -F SB_RD 2>/dev/null
    iptables -t nat -X SB_RD 2>/dev/null
    ip6tables -t nat -D PREROUTING -i $LAN_IF -p udp --dport 53 -j REDIRECT --to-ports $DNSPORT 2>/dev/null
    iptables -t mangle -D OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null
    echo "rules removed"
}

case "$1" in
    remove) remove_rules ;;
    *) apply_rules ;;
esac
