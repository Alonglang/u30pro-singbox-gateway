#!/system/bin/sh
# sing-box 透明代理守护脚本（放 /data/adb/service.d/，Magisk 开机自动执行）
# 功能：等开机完成 → 起 sing-box → 挂透明代理规则 → 30s 周期守护 → 每 7 天自动更新 geosite/geoip
# 注意：check_rules 检查的表/链必须与 tproxy_rules.sh 实际使用的一致（本方案为 nat 表 SB_RD）

base=/data/adb/singbox

# 等系统启动完成
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 10

start_singbox() {
    if ! pidof sing-box >/dev/null 2>&1; then
        > "$base/singbox.log"
        nohup "$base/sing-box" run -D "$base" -c "$base/config.json" >> "$base/singbox.log" 2>&1 &
        sleep 3
    fi
}

check_rules() {
    iptables -t nat -C PREROUTING -i br0 -p tcp -j SB_RD 2>/dev/null
}

# 初始启动
start_singbox
sh "$base/tproxy_rules.sh" 2>/dev/null
touch "$base/.geosite_last_update"

# 守护循环
while true; do
    sleep 30
    # sing-box 死了 → 先摘规则（直连保底）再重启
    if ! pidof sing-box >/dev/null 2>&1; then
        sh "$base/tproxy_rules.sh" remove 2>/dev/null
        start_singbox
        sh "$base/tproxy_rules.sh" 2>/dev/null
    # 进程活着但规则被 netd/网络切换重刷 → 重挂
    elif ! check_rules; then
        sh "$base/tproxy_rules.sh" 2>/dev/null
    fi
    # 每 7 天更新一次 geosite/geoip srs（失败不影响运行）
    now=$(date +%s); last=$(stat -c %Y "$base/.geosite_last_update" 2>/dev/null || echo 0)
    if [ $((now - last)) -gt 604800 ]; then
        touch "$base/.geosite_last_update"
        sh "$base/update_geosite.sh" >> "$base/singbox.log" 2>&1
    fi
done
