# u30pro-singbox-gateway

> 把一台 **已 root 的 Android 随身 WiFi / 随身路由** 变成**透明代理网关（科学上网路由器）**：连它的 WiFi 即自动分流上网，客户端零配置。

这是一个 **针对中兴 U30 Pro（MU5358）随身 WiFi 的透明代理实践**，沉淀为 **AI Agent 技能（Skill）**——部署、排障、升级全部由 AI 按技能指引代劳，用户只需提供节点信息。方案在 U30 Pro（B24 固件 + Magisk root）真机上完整部署并长期运行验证，所有坑都来自实战踩雷；其他已 root 且做 WiFi 热点的 Android 设备理论上适用（接口名/网段按实际调整），但以 U30 Pro 为唯一验证基准。

## 项目背景与依赖链

本方案不是从零开始——它是两层工程的上层，部署前请先理解依赖关系：

```
第 1 层：U30 Pro Root（前置工程，本仓库不包含）
   └── 中兴 U30 Pro（MU5358）B24 固件：TrustOS 解锁 + Magisk 30.7 root + UFI-TOOLS 高级后台
       完整流程见：https://github.com/qwXZhong/u30pro-b24-root-skill
       ↳ 产出：可用 /debug_ramdisk/su 提权、Magisk service.d 自启机制、adb 通道
第 2 层：本仓库 —— sing-box 透明代理网关（建立在 root 之上）
   └── sing-box + iptables 透明代理 + DNS 劫持分流 + Magisk 守护
```

**没有第 1 层就没有第 2 层**：本方案的每一步（写 `/data/adb`、iptables REDIRECT/TPROXY、service.d 开机自启）都依赖 root 权限。U30 Pro B24 的 root 是一段独立的完整工程（解锁有变砖风险、需完整备份），已由 [u30pro-b24-root-skill](https://github.com/qwXZhong/u30pro-b24-root-skill) 解决——**本方案的验证设备正是通过它完成 root 的**。其他设备的 root 请参考对应机型的方案，完成后用仓库内的「root 就绪验证三条」确认再开始部署。

## 它能做什么

连上这台设备的 WiFi 后，无需任何客户端配置：

- 🔀 **智能分流**：国内域名/IP 直连（geosite-cn + geoip-cn 双层判断），其余流量走你的代理节点（trojan/vless 等）
- 🛡️ **DNS 防污染**：所有 DNS 查询劫持进 sing-box，国内域名走本地 DNS，国外域名经代理 DoH（1.1.1.1）解析——无污染、无泄漏
- 🚫 **IPv6 泄漏防护**：AAAA 查询拒绝 + v6 DNS 劫持（内核支持时），杜绝"多 DNS 并发抢答被污染"的经典问题
- 📦 **规则集自动更新**：官方 sing-geosite/sing-geoip srs 每周自动更新（下载校验通过才替换，失败零影响）
- 🚀 **TPROXY 进阶路线**：内置完整升级手册，支持 TCP+UDP 全透明与 IPv6 透明（默认 REDIRECT 模式已够日常使用）
- 👻 **开机自启 + 守护**：Magisk service.d 开机启动，30 秒周期守护（进程挂了自动拉起、iptables 规则被系统重刷自动恢复）
- 📶 **蜂窝网络调优**：TCP MSS 钳制，解决随身 WiFi 场景大包被丢导致的"网页能开但加载忽快忽慢"

## 前提条件（硬性）

**本方案完全建立在设备已 root 之上**——先 root，再谈部署：

1. **U30 Pro 用户**：先完成 B24 固件的 TrustOS 解锁 + Magisk root——使用 [u30pro-b24-root-skill](https://github.com/qwXZhong/u30pro-b24-root-skill)（本方案的验证设备即由它完成 root）；**其他设备**：先完成对应机型的解锁 + Magisk 安装
2. root 就绪验证三条全过：`su -c id` 出 `uid=0`、`/data/adb` 可写、`service.d` 可创建（U30 Pro 的 su 全路径为 `/debug_ramdisk/su`）
3. 电脑侧 adb 可连设备
4. 一个**已在普通客户端验证可用**的代理节点（协议/域名/端口/凭据）

未 root 的设备此方案不可行——iptables REDIRECT/TCPMSS、/data/adb 写入、Magisk 自启都需要 root，也没有等效的免 root 替代。

## 仓库结构

```
├── SKILL.md                     # 技能主文档：方案选型、架构图、十二个实战坑速查
├── assets/                      # 部署模板（占位符待替换你的节点信息）
│   ├── config.json              # sing-box 配置（透明代理+DNS分流+AAAA拒绝）
│   ├── tproxy_rules.sh          # iptables 规则·REDIRECT 模式（默认）
│   ├── tproxy_rules_full.sh     # iptables 规则·TPROXY 模式（进阶，TCP+UDP+v6）
│   ├── 99-singbox.sh            # Magisk 守护脚本（开机自启+30s保活+每周更新）
│   └── update_geosite.sh        # 官方规则集下载校验原子替换
└── references/
    ├── deployment.md            # 从零部署手册（架构参考+6步部署+验证清单）
    ├── tproxy-upgrade.md        # TPROXY 升级手册（UDP全透明+IPv6，含回退）
    └── troubleshooting.md       # 9个真实案例+诊断方法论+工具坑备忘
```

## 快速开始

把本仓库放进你的 agent 技能目录（如 `~/.agents/skills/u30pro-singbox-gateway/`），然后对 AI 说：

> 帮我把这台已 root 的随身 WiFi 配成 sing-box 透明代理网关

AI 会按技能指引工作：先跑 root 就绪验证三条 → **主动向你询问节点信息**（协议 / 服务器域名 / 端口 / 密码——你不提供它不会猜）→ 自动替换模板占位符并完成全部部署（放文件、下载官方规则集、启动 sing-box、挂 iptables 规则、起 Magisk 守护）→ 跑完验证清单后向你汇报结果。**全程你只需要提供节点信息。**

部署后验证（在连该设备 WiFi 的电脑上）：

```bash
curl -s -o /dev/null -w '%{http_code}' https://www.google.com/generate_204   # 204 = 代理通
curl -s -o /dev/null -w '%{http_code} %{time_total}s' https://www.taobao.com # 200 + 亚秒 = 直连快
```

## 十个实战坑（详见 SKILL.md）

1. 自制 geosite json 把域名放 `domain`（精确匹配）→ 所有子域名分流失效 → 用官方 srs 根治
2. DNS 劫持端口被系统 mdnsd 抢占 → DNS 全灭
3. iptables 规则被 netd/网络切换重刷丢失 → 守护 30s 保活，检查表/链必须一致
4. 蜂窝 PMTU 可低至 ~1380 → TCP MSS 钳制 1300
5. Windows 并发查多 DNS 被 v6 抢答污染 → AAAA reject
6. `pkill -f 脚本名` 自杀 / toybox sed 不支持 `0,/re/` / Git Bash adb push 路径被转换 ……

## 适用设备

- ✅ **中兴 U30 Pro（MU5358，B24 固件）**：本方案的原生验证设备——root（u30pro-b24-root-skill）+ 透明代理全链路真机长期运行
- 🔄 其他 Magisk root 且做 WiFi 热点/路由的 Android 设备：理论适用（iptables/内核能力是 Android 通用的），接口名/网段按实际探测调整，**未经一一验证**

## 声明

本项目仅供网络技术与 Linux/Android 系统学习研究。使用者应遵守所在地区法律法规，对自行部署和使用产生的后果自负。

## License

MIT
