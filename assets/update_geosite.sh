#!/system/bin/sh
# 官方 geosite/geoip srs 规则集更新（经设备本地代理 127.0.0.1:2080 下载，绕过直连封锁）
# 安全设计：下载成功且魔数(SRS)/大小校验通过才原子替换并重启 sing-box；
#           任何失败保持现有文件不动——弱网环境下永不因更新把代理搞挂。

cd /data/adb/singbox || exit 1
P="--socks5-hostname 127.0.0.1:2080 -s -m 60"

ok=1
curl $P -o geosite-cn.new https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs || ok=0
curl $P -o geoip-cn.new   https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs   || ok=0

[ "$(head -c 3 geosite-cn.new 2>/dev/null)" = "SRS" ] || ok=0
[ "$(head -c 3 geoip-cn.new 2>/dev/null)"   = "SRS" ] || ok=0
[ "$(stat -c%s geosite-cn.new 2>/dev/null || echo 0)" -gt 10000 ] || ok=0
[ "$(stat -c%s geoip-cn.new 2>/dev/null || echo 0)"   -gt 10000 ] || ok=0

if [ "$ok" = "1" ]; then
    mv -f geosite-cn.new geosite-cn.srs
    mv -f geoip-cn.new   geoip-cn.srs
    pkill -f "singbox/sing-box"
    sleep 1
    nohup /data/adb/singbox/sing-box run -D /data/adb/singbox -c /data/adb/singbox/config.json >> /data/adb/singbox/singbox.log 2>&1 &
    echo "$(date '+%F %T') geosite/geoip srs updated, sing-box restarted"
else
    rm -f geosite-cn.new geoip-cn.new
    echo "$(date '+%F %T') update failed or validation error, keeping current files"
fi
