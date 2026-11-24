# luci-app-likepc（LuCI 里显示为「模拟pc」）

把「一台在校园网里求生的路由器」该有的工具做成 LuCI 界面按钮：**外网连通检测与告警**、
**被拉黑自动换 WAN MAC**、**一键添加防火墙规则（自动适配 firewall3 / firewall4）**、
**一键把 WAN 伪装成 Windows 电脑**，外加一份**出网特征体检报告**和 10 项出网特征加固 + 4 项流量拦截（都是一个按钮一个开关）。

**这个包不含认证。** 门户探测、提交表单、账号密码那一整套都没有（认证逻辑在另一个包里，不在本仓库）。

- **适用固件**：ImmortalWrt 23.05 / 24.10 / master 等 **JS 版 LuCI** 的 OpenWrt 固件
- **防火墙**：**firewall3（iptables）和 firewall4（nftables）都支持**，进页面自动识别并选对应写法
- **依赖**：只依赖 `luci-base`（防火墙扩展刻意不写进编译依赖，见 [依赖策略](#依赖策略为什么不写进编译依赖)）
- **菜单位置**：服务 → 模拟pc

---

## ⚠️ 先读这一段

这套工具做的事情，本质上是让一台路由器在网络管理员眼里「更像一台普通电脑」：
改 MAC、改 TTL、伪装 DHCP 指纹、屏蔽上游的探测包，等等。

- 请只用在你**自己拥有或明确获得授权**的网络、带宽和设备上。
- 很多校园网和单位网络的**使用协议里明确禁止私接路由器、共享上网**。使用本项目可能违反协议，
  由此产生的后果（断网、封号、按校规或当地法规处理）由使用者自行承担。
- 作者不对任何人使用本项目的后果负责。**不要拿它去动别人的网络。**

如果你只是想要一个好用的路由器固件，OpenWrt 官方固件就够了，不需要这个。

---

## 目录

- [功能一：外网检测与告警](#功能一外网检测与告警)
- [功能二：防拉黑换 MAC](#功能二防拉黑换-mac预生成-5-个不通时轮换)
- [功能三：一键添加防火墙规则](#功能三一键添加防火墙规则)
- [功能四：一键伪装成 Windows 电脑](#功能四一键伪装成-windows-电脑)
- [功能五：出网特征体检与逐项加固](#功能五出网特征体检与逐项加固)
- [界面说明](#界面说明)
- [安装](#安装)
- [目录结构](#目录结构)
- [命令行速查](#命令行速查)
- [UCI 选项速查](#uci-选项速查)
- [排错](#排错)
- [设计上的一些取舍](#设计上的一些取舍)
- [许可](#许可)

---

## 功能一：外网检测与告警

- 用 ping 检测外网，目标地址可以填多个（默认 `119.29.29.29`），检测间隔、重试次数都能配。
- **两个独立开关**：`开机自动运行`（开机检测一轮）和 `防掉线检测`（常驻盯着，掉线就按开关自动处理）。
- **连续失败告警**：每失败一轮就累加一次「连续失败」计数（写在 `/tmp/likepc.fails`），
  **外网恢复正常时自动清零**。达到 `alert_threshold`（默认 3）次后，页面顶部出现红色告警横幅，
  显示失败次数和时间；再到阈值的 3 倍时升级成更醒目的「外网持续不通」样式。
  横幅右边有「清除告警」按钮（等价于命令行 `alertclear`），点了计数归零、重新开始计。
- 关掉「连续检测失败时弹告警」就完全不产生告警，但计数仍在后台照常累计。
- 只想有告警但不想常驻检测？把「防掉线检测」关掉后，开机那一轮检测不通同样会告警。

> 提醒：外网不通的时候外网本身就不通，所以这里只做**界面告警**（不往外发通知），
> 否则推送也发不出去。要做到断网也能收到通知，得走局域网内一台常开设备转发。

按钮：`立即检测外网`、`检测并尝试恢复`、`启动 / 重启服务`、`停止服务`。

## 功能二：防拉黑换 MAC（预生成 5 个，不通时轮换）

- 安装时会**预先生成 5 个 MAC**（也可在界面点「重新生成 5 个 MAC」随时重来）。
- MAC 风格默认是螃蟹网卡前缀 `00:e0:4c` + 3 字节随机；前缀池可在界面改（如 `00:e0:4c 52:54:00`）。
- 生成用内核随机源 + **本机唯一因子（machine-id / 本机网卡 MAC）异或**，
  所以两台设备同时生成也不会得到同一个 MAC；本机还会把用过的 MAC 记到
  `/etc/likepc/mac-history`，保证不重复。
- 打开「启用防拉黑」后：**检测到外网连续不通时自动换成池中的下一个 MAC**（重启 WAN → 等待 → 重新检测），
  一轮最多连续换 `mac_max_rotate` 次，两次自动换之间至少间隔 `mac_cooldown` 秒；
  换完还是不通就停手，等下一轮检测。
- **DHCP client-id 会跟着 MAC 一起换**：Windows 发出去的 client-id 就是「01 + 自己的 MAC」，
  两者对不上本身就是个特征。所以只要 WAN 接口上的 client-id 长得像「01 + 12 位十六进制」，
  换 MAC 时会自动同步成 `01<新 MAC>`；开着「伪装成 Windows 电脑」而 client-id 空着，也会顺手补上。
  其它写法（比如固定字符串）一律不碰。点「恢复 WAN 原始 MAC」时，client-id 会一起还原
  （原值记在 `mac_orig_clientid` 里）。
- **电脑名也跟着 MAC 走**：开着 PC 伪装时，换 MAC 等于换了一台机器，主机名会一起换成新的。
  没开伪装、或者没换 MAC，这个名字一直不变（见[功能四](#功能四一键伪装成-windows-电脑)）。

按钮：`重新生成 5 个 MAC`、`立即切换到下一个 MAC`（首次会应用第一个）、`恢复 WAN 原始 MAC`。

## 功能三：一键添加防火墙规则

点「一键添加防火墙规则」时会**先检测防火墙版本，再选对应写法**：

- **firewall3（iptables）**：写入 `/etc/likepc/firewall.sh`，并在 `/etc/config/firewall`
  里加一条 `config include`（`type script`），重启/重载防火墙后规则自动恢复。规则内容：
  NTP 重定向到本机、客户端 NTP 强制本地（`ntp_force_local` 链 + DNAT 到路由器地址）、
  DNS（UDP/TCP 53）重定向到本机 dnsmasq、`POSTROUTING` 统一 TTL 为 128、
  屏蔽校园网下发页面里的 `src="http://1.1.1.` 探测包（`-m string`）。
- **firewall4（nftables）**：写入 `/etc/likepc/fw4.nft`，并在 `/etc/config/firewall`
  里加一条 `config include`（`type nftables`、`position table-prepend`），
  由 fw4 渲染规则集时把它 include 进 `table inet fw4` 内部。
  实现 TTL 128 + DNS / NTP 重定向，**并且把「门户探测包」那条也补齐了**：
  nftables 没有 `-m string` 这种按正文匹配的能力，所以改成**拦请求**——局域网设备访问探测地址
  （默认 `1.1.1.0/24`）的 80 端口直接丢掉。浏览器一样拿不到那个探测脚本，校园网也就看不到设备
  发起的这个连接；副作用反而更小：不会误伤正文里恰好含那串字符的正常网页。
  地址段在界面「探测地址段」里可改（`fw_probe_cidr`，可写多个，逗号分隔），
  不想用就在界面关掉「屏蔽门户探测地址」（`fw_probe_block=0`）。

两个平台的对照：

| | firewall3（iptables） | firewall4（nftables） |
| --- | --- | --- |
| 规则文件 | `/etc/likepc/firewall.sh` | `/etc/likepc/fw4.nft` |
| 挂载方式 | `config include`，`type 'script'` | `config include`，`type 'nftables'` |
| DNS / NTP 劫持 | `nat` 表 + `ntp_force_local` 链 + `REDIRECT` / `DNAT` | `chain likepc_redirect`（`hook prerouting`，`dnat` / `redirect`） |
| TTL 统一 | `mangle` 表 `-j TTL --ttl-set 128` | `ip ttl set 128` |
| 屏蔽门户探测包 | `-m string` 按**响应正文**丢包 | 按**目标地址**拦请求，效果相同且不会误伤正常网页 |

其它要点：

- 加规则前会先跑一次 `fw4 -q check` 做语法自检，**不通过就自动撤销**，避免把整机防火墙搞挂。
- 关于「防火墙 → 自定义规则」：这一页的显示条件依赖 **firewall3 的组件**
  （`/usr/share/fw3/helpers.conf`），所以在纯 fw4 系统上一般不出现，
  `/etc/firewall.user` 这个 include 也不是 fw4 的默认配置。
  本插件两种环境都不用那一页：fw3 走 `config include`（`type script`），
  fw4 走 `config include`（`type nftables`），规则跟随防火墙一起加载，卸载时自动撤掉。
- `192.168.0.0/16`、`192.168.1.1` 这类地址**不写死**：自动按 `network.lan` 的 IP/掩码算出
  LAN 网段和路由器地址，也可以在界面（`fw_lan_cidr` / `fw_router_ip`）手动覆盖。
- NTP 相关规则要求路由器自己当 NTP 服务器，默认勾了 `fw_ntp_server`，加规则时自动开 `sysntpd`。
- **规则模板写在编译源码里**：fw3 / fw4 的规则正文放在
  `root/usr/share/likepc/templates/fw3.sh`、`templates/fw4.nft`，编译进固件后位于
  `/usr/share/likepc/templates/`。点「一键添加防火墙规则」时插件把模板渲染成真正加载的文件
  （`/etc/likepc/firewall.sh`、`/etc/likepc/fw4.nft`），所以**要增删规则直接改模板重新编译即可**；
  模板不在时脚本会用内置规则兜底。
- **两个平台的行为是对齐的**：「屏蔽门户探测地址」这个开关在 fw3 / fw4 下都**双向生效** ——
  打开时生成对应规则，关掉后重新点一次「一键添加防火墙规则」就不会再写入那一条
  （fw3 是 `-m string` 那行，fw4 是 `likepc_probe` 链里的 drop），不会出现「界面关了、规则还在」。
- **fw3 缺扩展不会拖垮整套规则**：规则是逐条执行的，缺 `-m string` 时只有探测屏蔽那一条失败，
  缺 TTL 扩展时只有 TTL 那一条失败，其余 DNS / NTP 规则照常生效；执行完会扫一遍依赖，
  缺什么就在界面上点名，并给出对应的 `iptables-mod-*` / `kmod-ipt-*` 包名。

按钮：`一键添加防火墙规则`、`一键移除规则`、`查看当前规则`、`检测规则是否生效`、`添加 / 移除 fw4 规则`、`检测缺失模块`。

### 「已加载」不等于「在拦」：执法自检 / 防火墙模式 / WAN 兜底

有一类固件病（实测于 QSDK 系固件）：防火墙规则能正常渲染、加载，链也在，
**但内核根本不执行** —— 界面显示「已加载」，实际一条都没拦。三个配套机制：

- **检测规则是否生效**（`fwprobe`）：读模板规则的命中计数（fw3 用 `iptables-save -c`，
  fw4 用 nft 的 counter），再发一个本机回环包实测 postrouting 钩子是否真的在跑。
  计数不动会直接告诉你「内核很可能没有执行这些规则」，并给出下面的建议。
- **防火墙模式**（`fw_force`）：默认 auto 自动识别；fw3/fw4 并存或 nftables 执行异常的
  机器可强制 `firewall3`，走 iptables 路径（这类机器上 iptables 往往才是能用的那套）。
- **WAN 入站防护兜底**（`fw_wan_guard`）：一键加规则时，用 legacy iptables 把 wan 区
  入站策略再实现一遍（仅放行 已建立连接 / DHCP 续约 / ping，其余 REJECT）。
  正常固件上是双保险，执行异常的固件上是唯一可靠的防线；`fwdel` 时自动撤掉。
- 体检报告里对应两行：**规则执法**（规则加载了但计数恒 0 会标 ✕）和
  **include 健康**（别的插件写坏的 include 段 —— 值里带引号、路径不存在 ——
  实测能让 fw4 下次重启渲染崩溃、整机裸奔，报告会点名建议删除）。

### 依赖策略（为什么不写进编译依赖）

`Makefile` 里只有 `LUCI_DEPENDS:=+luci-base`，**故意不声明**下面这些防火墙扩展：

| 环境 | 缺了会影响的规则 | 缺什么会点名 |
| --- | --- | --- |
| firewall3 | `-m string` 探测包屏蔽 | `iptables-mod-filter` / `kmod-ipt-filter` |
| firewall3 | `TTL --ttl-set 128` | `iptables-mod-ipopt` / `kmod-ipt-ipopt` |
| firewall4 | 无（用原生 nft 规则，不需要内核扩展） | — |

原因：这些包在各家固件里包名和可用性都不一致，写进 `LUCI_DEPENDS` 会让**整包编译直接失败**。
插件改成**运行时检测**：点「一键添加防火墙规则」前会先扫一遍，
缺什么就在 LuCI 上弹提示（含可复制的安装命令），同时在「当前环境」里显示一行「缺少依赖」。
需要的话自己把对应 `kmod` / `iptables-mod-*` 编进固件即可（也可点「安装缺失模块」现场装）。

## 功能四：一键伪装成 Windows 电脑

点「一键伪装 Windows PC」会给 WAN 口设置一套 Windows 风格的 DHCP 特征（原值会先备份）：

| 项目 | 值 |
| --- | --- |
| 主机名 option 12 | `LAPTOP-XXXXXXX`（7 位随机大写字母数字，前缀可选 LAPTOP / DESKTOP / 随机） |
| vendor class option 60 | `MSFT 5.0` |
| client id option 61 | `01<当前 WAN MAC>`（Windows 用 MAC 做 client-id，换 MAC 时会自动跟着更新） |
| 请求参数列表 option 55 | `1 3 6 15 31 33 43 44 46 47 119 121 249 252`（Win10/11 典型） |

可选 `pc_random_mac=1`：顺便把 WAN MAC 换成普通 PC 网卡厂商前缀（Intel / DELL / HP / Lenovo /
ASUS / Acer，池可改）。点「恢复原始网络参数」可一键还原。

**电脑名的工作方式**：伪装时生成一个名字写进 `network.<WAN 接口>.hostname`，之后一直是同一个 ——
真实电脑的名字是稳定的，每天换名字反而在 DHCP 日志里显眼。只有两件事会让它变：

| 动作 | 会换名字吗 |
| --- | --- |
| 被拉黑自动换 MAC | **会**（换 MAC 等于换机器） |
| 手动「切换到下一个 MAC」 | 会 |
| 点「换一个电脑身份」 / 重新点一次「一键伪装」 | 会 |
| 开机、重启服务、关掉伪装 | 不会（关掉伪装会把原主机名还原回去） |

> 想换身份就点卡片上的「换一个电脑身份」。这个名字只在 WAN 走 DHCP 时才真正发出去；
> 如果 WAN 是 PPPoE 或静态 IP，这一项在线上不起作用。

> UA 等流量特征层面的伪装建议继续用你已有的 ua3f，本插件不重复实现，避免两套打架。

## 功能五：出网特征体检与逐项加固

点「重新体检」会逐条检查这台机器从校园网看过去有没有「不像电脑」的地方，结果按
`✓ 没问题 / ! 注意 / ✕ 有问题 / · 说明` 四档列在页面上（同样的内容也写在 `/tmp/likepc.harden`）。
体检覆盖：防火墙版本、**规则执法**（规则加载了内核有没有真的在执行）、**NSS/ECM 加速**（QSDK 防火墙被绕过的根源）、**include 段健康**
（别的插件写坏的段可能让防火墙下次重启崩掉）、IPv6 请求、内网 IPv6、odhcpd、软/硬件流量卸载、
TTL 统一、MSS 统一、DHCP 指纹、WAN 是否在网桥里、定时联网服务、路由/组播守护进程、网桥 IGMP 嗅探、
mDNS 是否从 WAN 外泄、监听面（uhttpd/dnsmasq/nmbd/vsftpd 是否还听在所有地址）、
孤儿物理口 IPv6（DSA 主口等）、**单设备出网**（有没有内网源地址未经 NAT/本机重发直出）。
页面下半部分另有 4 项「流量拦截」开关（P2P / 远程控制 / STUN / 对称 NAT），同样是一键应用、一键撤销。

下面是 10 项**逐项加固**，每项都是独立的一对「应用 / 撤销」按钮：

| 项 | 做了什么 | 撤销时 |
| --- | --- | --- |
| **IPv6 全关** | WAN 不再请求 IPv6（地址和前缀都不要）、内网不发 RA/DHCPv6，另装一个热插拔脚本防止被重新打开 | 用备份整体还原 `network` 和 `dhcp` |
| **关掉流量卸载与限速** | 关掉 `flow_offloading` / `flow_offloading_hw`，并停掉限速类服务 | 还原 `firewall` 配置并恢复服务 |
| **统一出网特征（TTL + MSS）** | 出网 TTL 钉成 128（Windows 的值）、TCP MSS 钉成 1460 | 只删本插件自己加的那部分 |
| **DHCP 指纹 + 电脑身份** | 伪装成 Windows 电脑（`LAPTOP-XXXXXXX` / `MSFT 5.0` / client-id 跟随 MAC） | 还原成原来的网络参数 |
| **掐掉定时联网的服务** | 停掉 umdns / mwan3 / watchcat / banip / adblock / 自动更新检查 / ddns / collectd 这类会定时主动往外发东西的服务 | 按名单逐个恢复原来的启动状态 |
| **关掉路由 / 组播协议** | 停掉 OSPF / RIP / BGP / PIM / IGMP 代理（bird / babeld / ospfd / ripd / bgpd / pimd / smcroute / igmpproxy 等），并关掉网桥的 IGMP 嗅探 | 按名单恢复原来开着的服务，IGMP 嗅探回到原来的值 |
| **关掉 mDNS 外泄（avahi）** | 把 avahi 的 `allow-interfaces` 限制成内网网桥：内网的 `.local` 自动发现照常，WAN 上不再宣告「主机名.local」（这个名字和伪装出来的 `LAPTOP-XXXXXXX` 对不上，是最容易被抓的矛盾点）。配置改不动或改完起不来时，自动退化成停用 avahi | 还原 avahi 配置，按名单恢复服务 |
| **监听面收窄** | 管理界面（uhttpd）只监听内网 IP、dnsmasq 不再监听 WAN 接口（notinterface）、vsftpd 只绑内网 IP、samba 停用 NetBIOS（nmbd 不再启动，445 共享不受影响）、闲置的 wsdd2（WSD/LLMNR）和 xl2tpd（无配置时）停用、ksmbd 收不了会在日志点名。只动监听地址，防火墙那层 REJECT 仍保留，两层互不替代 | 还原各服务的监听设置，按名单恢复被停掉的服务 |
| **物理口 IPv6 全关** | 把「IPv6 全关」管不到的孤儿物理口（DSA 主口 eth0 这类不被 UCI 管理的口）的 IPv6 也关掉：网桥、无线、被 interface/device 段占用的设备一律不碰；重启后由 sysctl / 热插拔自动保持 | 按记录还原各口原来的 IPv6 内核参数 |
| **关闭 NSS/ECM 加速** | QSDK 平台的 NSS/ECM 会在 netfilter 之前处理外部新连接，防火墙规则「已加载」也拦不住（fwprobe 可证实）。停掉 qca-nss-ecm 并卸载 ecm 模块，数据路径回落内核协议栈，防火墙恢复执法；WiFi 依赖的 nss_drv 不动。非 QSDK 平台提示不需要处理 | 按名单恢复服务并重新加载模块 |

### 流量拦截（对所有内网设备生效，4 个独立开关）

只作用于「内网 → WAN」的转发，路由器自己发起的流量不受影响。端口清单写死成白名单式，
不开放自定义大范围；`27015-27050`（CS2 / Dota / Steam）、`3074`（Xbox）、`5000-5500`
（LOL / 无畏契约）和 Discord 的随机高位 UDP 都不碰。

| 开关 | 封什么 | 对游戏的影响 |
| --- | --- | --- |
| **阻断 P2P 下载** | BT `6881-6999`、uTorrent `2710`、迅雷 `3076-3078`、eMule `4661-4672`、Transmission `51413`、`16881` | 无（这些不是游戏端口） |
| **阻断远程控制** | RustDesk `21115-21119`、TeamViewer `5938`、AnyDesk `6568`、VNC `5900-5901` | 无；走 443 的工具（向日葵、部分 ToDesk）拦不住 |
| **阻断 STUN / TURN** | `3478-3479`、`5349`、`19302-19309` | PSN / Xbox 派对语音受影响（也用 3478-3480）；普通联机游戏不受影响 |
| **强制对称 NAT（NAT4）** | 不是丢包：把 WAN 的 masquerade 改成 `random,fully-random`，同一内网设备访问不同目标会拿到完全不同的外部端口 | P2P 联机、主机派对可能变成严格 NAT 或改走中继；常规网游不受影响 |

> `阻断 P2P` 封的是**默认端口**。客户端把端口改成随机就拦不住 —— 那种情况只有
> 「强制对称 NAT」或整机断网才有用。

要点：

- **一次只开一项，改完观察几天再动下一项。** 断线本来就不规律，一次全开就永远不知道是哪条起的作用；
  页面顶部也写了这句提醒。
- **IPv6 那一项的撤销是「整体还原」**：点「应用」时会把 `network` 和 `dhcp` 备份下来，撤销就是把
  这两个文件还原回去 —— 这之后你手工改过的网络设置也会一起回退。卡片上也标了这条。
- **不碰 ICMP。** Windows 是回 ping 的，上游的存活探测也经常就用 ping；关掉等于自曝，
  而且 PMTU 发现依赖 ICMP，关掉会直接掉速。
- **隧道 / 代理 / 加密 DNS 只报告不动手**（openclash、passwall、sing-box、zerotier、tailscale、
  smartdns、upnpd 之类）：开不开属于你自己的判断范围，插件只会在报告里点名，不会替你关。
- **TTL 那一项会自动去重**：如果「一键添加防火墙规则」那份规则里已经带了 TTL，就不再加第二条；
  撤销时也只删自己加的那份，不动主规则。重复点「应用」也不会把自己刚加的 TTL 误判成主规则。
- **fw3 的 TTL + MSS 同样持久化**：不是直接往 iptables 里塞两条就完事（那样防火墙一 reload 就没了），
  而是写成 `/etc/likepc/harden.sh` 再挂 `config include`（`type script`），和设备重启 / 防火墙重载后
  自动恢复；fw4 则写成 `/etc/likepc/harden.nft`（`type nftables`）。两边都是一键应用、一键撤销。
- 各开关状态存在 `/etc/likepc/hd-*`，备份在 `/etc/likepc/bak/`，生成的 nft 规则在
  `/etc/likepc/harden.nft`（由 `firewall` 的 `include` 段以 `type nftables` 加载）。
- **fw3 / fw4 都能用**：fw4 下四组开关渲染成 `blocks.nft`（`config include`，`type nftables`）；
  fw3 下渲染成 `blocks.sh`（`config include`，`type script`）里的 `iptables` 规则。
  fw3 的端口列表先试 `-m multiport`，模块不在就自动退回逐条 `--dport`（范围写成 `a:b`），
  不依赖 `xt_multiport`；NAT4 也做了三级降级：`--random-fully` → `--random` → 普通 `MASQUERADE`，
  每一级都会写 `logger -t likepc`，方便在日志里确认实际生效的是哪一档。
- **撤销是彻底的**：四组全部关掉时会删除 include 段和规则文件；卸载时 `prerm` 还会再跑一次
  `blk-clear` 并清掉 `blocks.nft` / `blocks.sh`，不给系统留残留规则。

> 这些加固改的都是**本机**的行为特征（协议、定时任务、DHCP 字段），不会也不可能改变 UA、
> TLS 指纹那类流量层面的特征 —— 那些请交给别的工具。

---

## 界面说明

- **顶部状态卡片**：「服务状态」「外网状态」两个徽章，「当前 WAN MAC / WAN 设备」「最近一次检测」
  「备用的 5 个 MAC（当前的带 ✓ 高亮）」三张卡片，下面一排按钮：
  `立即检测外网`、`检测并尝试恢复`、`启动 / 重启服务`、`停止服务`。
- **红色告警横幅**：外网连续不通达到阈值时出现在页面顶部，右边有「清除告警」。
- **设置卡片**：带标签页（基本设置 / 高级设置 / 防拉黑 · 换 MAC）。
- **出网特征体检与加固**：一份体检报告 + 10 张逐项加固卡片，每张都有一对「应用 / 撤销」。
- **一键工具**：防火墙规则、fw4 专用入口、PC 伪装，以及「当前环境」（防火墙版本、规则状态、缺不缺依赖）。
- **运行日志**：深色日志窗口，可刷新、可清空。

> 截图待补：把截图放进 `docs/screenshots/`，然后在这里插入图片引用。

---

## 安装

### 方式一：编进固件（推荐）

```bash
# 把这个仓库放到固件源码的 package/ 下
git clone https://github.com/<你的用户名>/luci-app-likepc.git <固件源码>/package/luci-app-likepc

make menuconfig     # LuCI -> Applications -> luci-app-likepc（只依赖 luci-base）
make package/luci-app-likepc/compile V=s
```

生成的 ipk 在 `bin/packages/<架构>/base/` 下。也可以直接把整个目录拷进 `package/` 再编译。

### 方式二：装 ipk

```bash
opkg update
opkg install luci-app-likepc_*.ipk
rm -rf /tmp/luci-* /tmp/luci-indexcache     # 或直接在 LuCI 里刷新
```

装完在 **服务 → 模拟pc**。

### 从旧版本升级

本插件由「校园网工具箱」改名而来（原 `luci-app-campus-tools`，以及更早的 `luci-app-campus-auth`
里的非认证部分）。`postinst` 会自动清理旧版本留下的服务、配置和 nft 表，不用手工删。
直接 `opkg remove luci-app-likepc` 时，`prerm` 会停服务、撤掉 fw3/fw4 的 include 段、
清掉 `fw4.nft` / `firewall.sh` / `blocks.nft` / `blocks.sh` / `harden.nft` / `harden.sh`，规则不会留在系统里。

---

## 目录结构

```
luci-app-likepc/
├── Makefile                                          # 编译脚本（luci.mk）
├── README.md                                         # 本文件
├── LICENSE                                           # Apache-2.0
├── htdocs/luci-static/resources/view/likepc/tools.js  # LuCI 页面（卡片式）
└── root/
    ├── etc/
    │   ├── config/likepc                            # 默认 UCI 配置
    │   ├── init.d/likepc                            # procd 服务（开机运行 / 防掉线）
    │   └── uci-defaults/99-luci-app-likepc          # 注册 ucitrack、预生成 5 个 MAC、清菜单缓存
    └── usr/
        └── share/
            ├── likepc/likepc.sh                     # 主脚本（外网检测 + 命令入口）
            ├── likepc/mac.sh                        # WAN MAC 生成 / 应用 / 轮换
            ├── likepc/fw.sh                         # 一键防火墙规则（fw3 / fw4）
            ├── likepc/pc.sh                         # 伪装 Windows PC
            ├── likepc/harden.sh                     # 出网特征体检 + 逐项加固
            ├── likepc/blocks.sh                     # 流量拦截（fw3 iptables / fw4 nftables）
            ├── likepc/templates/fw3.sh              # firewall3(iptables) 规则模板（随固件编译）
            ├── likepc/templates/fw4.nft             # firewall4(nftables) 规则模板（随固件编译）
            ├── luci/menu.d/luci-app-likepc.json
            ├── rpcd/acl.d/luci-app-likepc.json
            └── ucitrack/luci-app-likepc.json
```

---

## 命令行速查

调试时可以直接跑脚本，不必开界面：

```bash
/usr/share/likepc/likepc.sh check        # 只检测外网
/usr/share/likepc/likepc.sh recover      # 检测；不通且开了自动换 MAC 时轮换 MAC 再检测
/usr/share/likepc/likepc.sh once         # 等启动延迟后检测一轮
/usr/share/likepc/likepc.sh status       # 网络 + MAC 状态
/usr/share/likepc/likepc.sh daemon       # 前台常驻（调试）
/usr/share/likepc/likepc.sh genmac       # 重新生成 5 个 MAC
/usr/share/likepc/likepc.sh macnext      # 切到下一个 MAC
/usr/share/likepc/likepc.sh macrestore   # 恢复原始 MAC
/usr/share/likepc/likepc.sh fwadd | fwdel | fwshow | fwprobe | fwadd4 | fwdel4
/usr/share/likepc/likepc.sh deps | depinstall
/usr/share/likepc/likepc.sh pcfake | pcrestore | pcnewid
/usr/share/likepc/likepc.sh alertclear   # 清除失败告警并重新计数
/usr/share/likepc/likepc.sh harden       # 出网特征体检（结果写 /tmp/likepc.harden）
/usr/share/likepc/likepc.sh hd-ipv6 | hd-offload | hd-sig | hd-dhcp | hd-quiet | hd-routing | hd-mdns
/usr/share/likepc/likepc.sh hd-ipv6-undo | hd-offload-undo | hd-sig-undo | hd-dhcp-undo | hd-quiet-undo | hd-routing-undo | hd-mdns-undo
/usr/share/likepc/likepc.sh hd-listen | hd-ports | hd-ecm | hd-listen-undo | hd-ports-undo | hd-ecm-undo
/usr/share/likepc/likepc.sh blk-p2p | blk-remote | blk-stun | blk-nat4
/usr/share/likepc/likepc.sh blk-p2p-undo | blk-remote-undo | blk-stun-undo | blk-nat4-undo
/usr/share/likepc/likepc.sh blk-clear   # 四组全关并删掉 include 段/规则文件（卸载时也会自动跑）
/usr/share/likepc/likepc.sh applyall     # 一键应用全部并检测一次
/usr/share/likepc/likepc.sh info         # 输出环境信息给界面

/etc/init.d/likepc restart
cat /tmp/likepc.log ; logread -e likepc
```

---

## UCI 选项速查

配置文件 `/etc/config/likepc`：

| 选项 | 说明 | 默认 |
| --- | --- | --- |
| `enabled` / `monitor` | 开机自动运行 / 防掉线检测 | 0 / 1 |
| `ping_host` | 外网检测地址（可多个） | `119.29.29.29` |
| `check_interval` / `fail_threshold` | 检测间隔 / 连续失败几次后开始处理 | 30 / 3 |
| `alert_enable` / `alert_threshold` | 失败告警开关 / 连续失败几次后告警 | 1 / 3 |
| `start_delay` | 开机等多少秒再检测 | 15 |
| `ping_count` / `ping_timeout` | ping 探测参数 | 1 / 3 |
| `mac_auto` | 防拉黑：外网不通时自动换 MAC | 0 |
| `mac_pool` | 预生成的 5 个 MAC（list） | 安装时生成 |
| `mac_oui` | 随机 MAC 前缀池 | `00:e0:4c` |
| `mac_index` | 当前使用池中的第几个 | 0 |
| `mac_max_rotate` / `mac_cooldown` / `mac_settle` | 最多连换几次 / 冷却秒 / 换后等待秒 | 5 / 600 / 10 |
| `mac_original` / `mac_orig_clientid` | 首次换 MAC 前记录的原始值（点「恢复原始 MAC」时还原） | 空 |
| `wan_device` / `wan_iface` | WAN 设备名 / 接口名（留空或 auto 自动识别） | auto |
| `fw_ntp_server` | 加规则时开启路由器 NTP 服务 | 1 |
| `fw_force` | 防火墙模式：auto / 3 / 4（混合固件强制 iptables 路径） | auto |
| `fw_wan_guard` | 一键加规则时启用 legacy iptables 版 WAN 入站兜底 | 0 |
| `fw_lan_cidr` / `fw_router_ip` | 手动指定 LAN 网段 / 路由器地址 | 空（自动） |
| `fw_probe_block` / `fw_probe_cidr` | 屏蔽门户探测地址 / 探测地址段（可多个） | 1 / `1.1.1.0/24` |
| `pc_fake` / `pc_prefix` / `pc_random_mac` | 伪装状态 / 主机名前缀 / 是否换 PC 风格 MAC | 0 / random / 0 |
| `pc_orig_*` | 伪装前的原始 DHCP 参数备份 | 空 |

---

## 排错

- **一直显示外网不通**：先确认 WAN 拿到了地址（界面里的网络状态，或 `ip addr`），
  再看 `/tmp/likepc.log`。**本插件不做认证** —— 校园网需要登录的话，请自行登录或另配认证脚本。
- **换 MAC 后没网**：点「恢复 WAN 原始 MAC」，或检查 `wan_device` 填得对不对
  （日志里会打印识别到的 WAN 设备名）。
- **防火墙规则没生效**：先看界面「当前环境」里的规则状态和扩展是否齐全。
  点「一键添加防火墙规则」时如果缺东西，界面会直接弹「缺少依赖：…」，
  按提示把对应扩展编进固件，再确认 `fw_lan_cidr` 与实际局域网一致。
- **规则加载了但不拦（QSDK 类固件）**：点「检测规则是否生效」（`fwprobe`）——
  有的固件 nftables 规则能加载但内核不执行。确认后把「防火墙模式」强制成
  firewall3 走 iptables 路径，并打开「WAN 入站防护兜底」。
- **防火墙重启后起不来**：看体检报告「include 健康」一行 —— 别的插件写坏的
  include 段（值带引号 / 路径不存在）会让 fw4 渲染崩溃，按点名删掉对应段即可。
- **加 nft 规则后防火墙起不来**：本插件加规则前会先 `fw4 -q check` 自检，不通过会自动撤销，
  不会出现这种情况；如果手工改过 `/etc/likepc/fw4.nft`，点一次「一键移除规则」即可恢复。
- **加固撤销后网络设置被回退了**：这是「IPv6 全关」的设计 —— 它整体还原 `network` / `dhcp`
  备份，不是逐条反向改。所以应用这一项之后如果还要改网络配置，先想清楚撤销的后果。
- **「路由 / 组播协议」这项**只动对应协议的守护进程和网桥 IGMP 嗅探，不碰正常上网设置；
  撤销时按名单把原来开着的服务恢复回去，IGMP 嗅探回到原来的值。
- **加固状态显示「未知」**：说明还没读到体检报告（`/tmp/likepc.harden` 重启后会清掉），
  点一次「重新体检」就有了。
- **改了内网网段后 LuCI 后台打不开**：先撤销「监听面收窄」再改网段 —— 它把 uhttpd 绑在了
  旧的内网 IP 上。已经改挂的话 SSH 进去执行 `/usr/share/likepc/likepc.sh hd-listen-undo`。
- **想改规则本身**：改源码里的模板 `root/usr/share/likepc/templates/fw3.sh` /
  `templates/fw4.nft` 后重新编译；设备上也可以直接改 `/usr/share/likepc/templates/` 下的同名文件，
  再点一次「一键添加防火墙规则」重新生成。
- **日志**：`/tmp/likepc.log` 超过 32KB 自动只留最近 300 行。

---

## 设计上的一些取舍

- **不含认证。** 认证那套逻辑与这个包分开维护，不在本仓库。
  注意：任何会改 WAN MAC / PC 伪装参数的工具都可能与本插件抢配置，**不要和它们同时启用**。
- **不碰 ICMP。** 见上文，Windows 会回 ping，关掉反而更可疑。
- **不做 UA / TLS 指纹伪装。** 那属于流量层面，和本插件的定位不同；两套一起上容易打架。
- **电脑名平时不变，换 MAC 时才跟着换。** 理由见[功能四](#功能四一键伪装成-windows-电脑)。
- **加固默认全关。** 装好不会自己动你的网络配置，每一项都要手动点。
- **撤销要干净。** 每一项加固都记录「原来是什么样」，撤销时按记录还原，而不是按固定值回写。
- **失败告警只做界面告警。** 外网不通时推送也发不出去。

---

## 许可

Copyright (C) 2026 topjy

以 Apache License 2.0 授权，全文见 [LICENSE](LICENSE)。

## 致谢

规则里的门户探测地址屏蔽、NTP 强制本地等写法，来自公开的校园网运维资料与社区讨论。
感谢 OpenWrt / ImmortalWrt 和 LuCI 项目。