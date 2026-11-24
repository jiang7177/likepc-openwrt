#!/bin/sh
# 出网特征加固 + 体检（likepc 的一部分）
# 由 likepc.sh source，不单独运行
#
# 这一层只做一件事：把「从校园网看过去，这台机器不像一台电脑」的地方逐条消掉。
# 每一项都是独立开关，可以单独应用、单独撤销：
#   hd_ipv6     关掉 IPv6（含前缀请求）
#   hd_offload  关掉流量卸载与限速，让 TTL 这类规则真正生效
#   hd_sig      统一出网特征：TTL 128 + MSS
#   hd_dhcp     伪装 DHCP 指纹
#   hd_quiet    掐掉所有会定时往外发东西的服务
#   hd_routing  关掉 OSPF / RIP / BGP / PIM / IGMP 代理与网桥 IGMP 嗅探
#   hd_mdns     把 mDNS 限制在内网，WAN 上不再宣告「主机名.local」
#
# 体检报告写在 /tmp/likepc.harden，每行格式：等级|名称|说明
#   等级 ok / warn / bad / info / sw（sw 行是各开关的状态）
#
# 提醒：一次只开一项，改完观察几天再动下一项。你的断线本来就不规律，
# 一次全开的话，永远不知道是哪条起的作用。

# 这几个根目录允许用环境变量覆盖，方便离线测试；设备上不设就是默认路径
HD_DIR=${HD_DIR:-/etc/likepc}
HD_CONF_DIR=${HD_CONF_DIR:-/etc/config}
HD_HOTPLUG=${HD_HOTPLUG:-/etc/hotplug.d/iface/99-likepc-ipv6}
HD_INITD=${HD_INITD:-/etc/init.d}
HD_BAK="$HD_DIR/bak"
HD_NFT="$HD_DIR/harden.nft"
HD_FW3="$HD_DIR/harden.sh"
HD_REPORT=/tmp/likepc.harden
HD_MSS=1460

# avahi 的配置文件：mDNS 外泄就出在它身上
HD_AVAHI_CONF=${HD_AVAHI_CONF:-/etc/avahi/avahi-daemon.conf}
HD_AVAHI_SVC=avahi-daemon

# 会定时主动往外发东西的服务：装了并且开着就停掉，撤销时按名单恢复
HD_QUIET_SVC="umdns mwan3 watchcat banip adblock attendedsysupgrade ddns collectd"

# 隧道 / 代理 / 加密 DNS：只报告不动手，这些要你自己判断
HD_WATCH_SVC="openclash clash passwall passwall2 ssr-plus shadowsocks-libev
	v2raya xray sing-box mihomo nikki dae byedpi homeproxy
	zerotier tailscale nebula frpc sshtunnel
	smartdns mosdns https-dns-proxy stubby dnscrypt-proxy
	upnpd miniupnpd"

# 路由 / 组播协议：家用 / 电脑直连的环境里一个都不该跑，跑了就是最明确的路由器特征。
# 前者是进程名（pidof 用），后者是 init 脚本名（要停还得能按名单恢复）。
HD_ROUTE_PROC="bird bird4 bird6 babeld ospfd ospf6d ripd ripngd bgpd pimd pim6d
	smcroute igmpproxy mcproxy zebra olsrd olsrd6"
HD_ROUTE_SVC="olsrd olsrd6 babeld bird bird4 bird6 quagga frr ospfd ospf6d
	ripd ripngd bgpd pimd pim6d smcroute igmpproxy mcproxy"

# 网桥 IGMP 嗅探的原值记在这里，撤销时照着还原
HD_IGMP_FILE="$HD_DIR/hd-routing-igmp"

# ------------------------------------------------------------------ 通用工具
hd_svc_exists() {
	[ -x "$HD_INITD/$1" ]
}

hd_svc_enabled() {
	hd_svc_exists "$1" || return 1
	"$HD_INITD/$1" enabled >/dev/null 2>&1
}

hd_stop_svc() {
	hd_svc_exists "$1" || return 0
	"$HD_INITD/$1" stop >/dev/null 2>&1
	"$HD_INITD/$1" disable >/dev/null 2>&1
	return 0
}

hd_start_svc() {
	hd_svc_exists "$1" || return 0
	"$HD_INITD/$1" enable >/dev/null 2>&1
	"$HD_INITD/$1" start >/dev/null 2>&1
	return 0
}

hd_svc_list_file() {
	echo "$HD_DIR/hd-svc-$1.list"
}

# 停掉一个服务，并把名字记进分组名单（撤销时照名单恢复）
hd_svc_record_stop() {
	local grp="$1" svc="$2" f

	hd_svc_enabled "$svc" || return 0

	f=$(hd_svc_list_file "$grp")
	mkdir -p "$HD_DIR"
	grep -qx "$svc" "$f" 2>/dev/null || echo "$svc" >>"$f"

	hd_stop_svc "$svc"
	log "已停用会主动联网的服务：$svc"
	return 0
}

hd_svc_restore() {
	local grp="$1" f svc

	f=$(hd_svc_list_file "$grp")
	[ -f "$f" ] || return 0

	while read -r svc; do
		[ -n "$svc" ] || continue
		hd_start_svc "$svc"
		log "已恢复服务：$svc"
	done <"$f"

	rm -f "$f"
	return 0
}

# 改 uci 之前把整份配置留个底；撤销时整体还原
# （不是逐项还原，因为 IPv6 那一项散在 network 和 dhcp 两个文件里，
#   逐项还原容易漏。界面上会说明这一点。）
hd_backup_file() {
	mkdir -p "$HD_BAK"
	[ -f "$HD_CONF_DIR/$1" ] || return 0
	cp "$HD_CONF_DIR/$1" "$HD_BAK/$1" 2>/dev/null
	return 0
}

hd_restore_file() {
	[ -f "$HD_BAK/$1" ] || return 1
	mkdir -p "$HD_CONF_DIR"
	cp "$HD_BAK/$1" "$HD_CONF_DIR/$1" 2>/dev/null
	return 0
}

# 各开关的状态标记
hd_flag() {
	local name="$1" val="$2"

	if [ -n "$val" ]; then
		mkdir -p "$HD_DIR"
		echo "$val" >"$HD_DIR/hd-$name" 2>/dev/null
		return 0
	fi

	local v
	v=$(cat "$HD_DIR/hd-$name" 2>/dev/null)
	[ -n "$v" ] || v=0
	echo "$v"
	return 0
}

hd_on() {
	hd_flag "$1" 1
}

hd_off() {
	hd_flag "$1" 0
}

# ------------------------------------------------------------------ 探测函数
hd_ifaces() {
	uci -q show network 2>/dev/null | grep '=interface$' | cut -d. -f2 | cut -d= -f1
}

# 哪个接口正在向校园网请求 IPv6（地址或前缀）
hd_ipv6_requesting() {
	local s p v

	for s in $(hd_ifaces); do
		p=$(uci -q get "network.$s.proto" 2>/dev/null)
		case "$p" in
			dhcpv6)
				v=$(uci -q get "network.$s.reqprefix" 2>/dev/null)
				case "$v" in
					none|disabled) ;;
					*) echo "$s"; return 0 ;;
				esac
				;;
			dhcp)
				v=$(uci -q get "network.$s.ipv6" 2>/dev/null)
				case "$v" in
					1|auto|try) echo "$s"; return 0 ;;
				esac
				;;
		esac
	done

	return 1
}

# 本机有没有全球 IPv6 地址（2xxx / 3xxx 开头）
hd_ipv6_lan_global() {
	ip -6 addr show 2>/dev/null | grep -qE 'inet6 (2[0-9a-fA-F]{3}|3[0-9a-fA-F]{3}):'
}

# WAN 口是不是被桥进了某个网桥
hd_wan_in_bridge() {
	local dev d

	dev=$(wan_device)
	[ -n "$dev" ] || return 1

	for d in /sys/class/net/*; do
		[ -e "$d/brif/$dev" ] || continue
		echo "${d##*/}"
		return 0
	done

	return 1
}

hd_ttl_present() {
	if [ "$(fw_version)" = "4" ]; then
		nft list ruleset 2>/dev/null | grep -q 'ttl set 128'
	else
		iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q -- '--ttl-set 128'
	fi
}

hd_mss_present() {
	if [ "$(fw_version)" = "4" ]; then
		hd_nft_include_section >/dev/null
	else
		iptables -t mangle -S POSTROUTING 2>/dev/null | grep -q -- "--set-mss $HD_MSS"
	fi
}

# 「主防火墙规则」里是否已经带了 TTL（不含本插件 hd-sig 自己加的那份）
# 用来决定：这次应用要不要把 TTL 也写进加固规则，避免重复应用时把自己的规则误判成主规则。
hd_main_ttl_present() {
	if [ "$(fw_version)" = "4" ]; then
		nft list chain inet fw4 likepc_ttl >/dev/null 2>&1
	else
		[ -f "$FW3_SCRIPT" ] && grep -q -- '--ttl-set 128' "$FW3_SCRIPT" 2>/dev/null &&
			fw_include_section >/dev/null
	fi
}

hd_nft_include_section() {
	local sec

	for sec in $(uci -q show firewall 2>/dev/null | grep '=include$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$(uci -q get "firewall.$sec.path" 2>/dev/null)" = "$HD_NFT" ]; then
			echo "$sec"
			return 0
		fi
	done

	return 1
}

hd_nft_include_add() {
	hd_nft_include_section >/dev/null && return 0

	uci -q add firewall include
	uci -q set firewall.@include[-1].type='nftables'
	uci -q set firewall.@include[-1].path="$HD_NFT"
	uci -q set firewall.@include[-1].enabled='1'
	uci -q commit firewall
	return 0
}

hd_nft_include_del() {
	local sec

	while sec=$(hd_nft_include_section); do
		uci -q delete "firewall.$sec"
		uci -q commit firewall
	done

	return 0
}

hd_fw3_include_section() {
	local sec

	for sec in $(uci -q show firewall 2>/dev/null | grep '=include$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$(uci -q get "firewall.$sec.path" 2>/dev/null)" = "$HD_FW3" ]; then
			echo "$sec"
			return 0
		fi
	done

	return 1
}

hd_fw3_include_add() {
	hd_fw3_include_section >/dev/null && return 0

	uci -q add firewall include
	uci -q set firewall.@include[-1].type='script'
	uci -q set firewall.@include[-1].path="$HD_FW3"
	uci -q set firewall.@include[-1].enabled='1'
	uci -q commit firewall
	return 0
}

hd_fw3_include_del() {
	local sec

	while sec=$(hd_fw3_include_section); do
		uci -q delete "firewall.$sec"
		uci -q commit firewall
	done

	return 0
}

hd_route_procs() {
	local p found

	found=""
	for p in $HD_ROUTE_PROC; do
		pidof "$p" >/dev/null 2>&1 && found="$found $p"
	done

	echo $found
}

# 正在跑、或者开着自启的路由 / 组播守护进程（并集，去重）
hd_route_found() {
	local p found

	found=$(hd_route_procs)
	for p in $HD_ROUTE_SVC; do
		hd_svc_enabled "$p" || continue
		case " $found " in
			*" $p "*) continue ;;
		esac
		found="$found $p"
	done

	echo $found
}

# 哪些网桥开着 IGMP 嗅探（没写这个选项时以内核实际状态为准）
hd_igmp_snoop_devs() {
	local s n t v

	for s in $(uci -q show network 2>/dev/null | grep '=device$' | cut -d. -f2 | cut -d= -f1); do
		n=$(uci -q get "network.$s.name" 2>/dev/null)
		t=$(uci -q get "network.$s.type" 2>/dev/null)

		if [ -z "$t" ] && [ -n "$n" ] && [ -f "/sys/class/net/$n/bridge/multicast_snooping" ]; then
			t=bridge
		fi
		[ "$t" = "bridge" ] || continue

		v=$(uci -q get "network.$s.igmp_snooping" 2>/dev/null)
		case "$v" in
			1|true|yes) echo "$s"; continue ;;
			0|false|no) continue ;;
		esac

		# 没写这个选项：OpenWrt 的网桥默认是开着的，看内核怎么说
		if [ -n "$n" ] && [ "$(cat "/sys/class/net/$n/bridge/multicast_snooping" 2>/dev/null)" = "1" ]; then
			echo "$s"
		fi
	done

	return 0
}

# ------------------------------------------------------------------ mDNS 探测
# avahi 默认在每一块网卡上响应 mDNS（WAN 也在内）。Windows 电脑不会在接入口上
# 宣告「主机名.local」，而且这个名字往往和伪装出来的 LAPTOP-XXXX 对不上。
hd_avahi_running() {
	pidof avahi-daemon >/dev/null 2>&1
}

# 当前 allow-interfaces 的值（没写就是空 = 所有网卡都用）
hd_avahi_allow() {
	[ -f "$HD_AVAHI_CONF" ] || return 0
	sed -n 's/^[[:space:]]*allow-interfaces[[:space:]]*=[[:space:]]*//p' "$HD_AVAHI_CONF" 2>/dev/null | tail -n 1
}

# 内网网桥（avahi 允许在这上面继续工作）
hd_lan_ifaces() {
	local d

	d=$(uci -q get network.lan.device 2>/dev/null)
	[ -n "$d" ] || d=$(uci -q get network.lan.ifname 2>/dev/null)
	[ -n "$d" ] || d=br-lan

	echo "$d" | tr ' ' ','
}

# mDNS 从哪跑出去：all = 所有网卡，接口名 = 那个口，空 = 没有外泄
hd_avahi_leak() {
	local allow dev

	hd_avahi_running || return 0

	allow=$(hd_avahi_allow | tr ' ' ',')
	if [ -z "$allow" ]; then
		echo all
		return 0
	fi

	dev=$(wan_device 2>/dev/null)
	[ -n "$dev" ] || dev=wan

	case ",$allow," in
		*",$dev,"*) echo "$dev" ;;
	esac

	return 0
}

# ------------------------------------------------------------------ 单设备出网
# 出网流量是否全部「本机重发或已 NAT」：扫 conntrack 里 LAN 源、目标非本机的流，
# reply 方向如果完全是原方向的镜像（中途没被 NAT/REDIRECT 改写），就是内网源
# 直出 —— 上游直接看到内网地址，是最响的多设备信号。
# 输出格式：示例(最多两条)|条数
hd_single_dev_leaks() {
	local pre out

	fw_lan_info 2>/dev/null
	pre=$(echo "$FW_LAN_CIDR" | cut -d/ -f1 | cut -d. -f1-3)

	[ -n "$pre" ] || { echo "|0"; return 0; }

	out=$(awk -v lan="${pre}." -v rip="$FW_ROUTER_IP" '
	/src=/ {
		o_src = ""; o_dst = ""; r_src = ""; r_dst = ""
		seen_src = 0; got_odst = 0; got_rdst = 0
		for (i = 1; i <= NF; i++) {
			if (substr($i, 1, 4) == "src=") {
				if (seen_src == 0) { o_src = substr($i, 5); seen_src = 1 }
				else if (r_src == "") r_src = substr($i, 5)
			}
			else if (substr($i, 1, 4) == "dst=") {
				if (got_odst == 0) { o_dst = substr($i, 5); got_odst = 1 }
				else if (got_rdst == 0) r_dst = substr($i, 5)
			}
		}
		if (o_src ~ ("^" lan) && o_dst !~ ("^" lan) && o_dst != rip &&
		    o_dst !~ /^(224\.|239\.|255\.255)/ &&
		    r_src == o_dst && r_dst == o_src) {
			n++
			if (n <= 2) printf "%s->%s ", o_src, o_dst
		}
	}
	END { printf "|%d\n", n + 0 }
	' /proc/net/nf_conntrack 2>/dev/null)

	echo "${out:-|0}"
	return 0
}

# ------------------------------------------------------------------ 体检报告
hd_row() {
	printf '%s|%s|%s\n' "$1" "$2" "$3"
}

hd_report() {
	local req dev v br found grp s hn

	{
		hd_row info "防火墙版本" "$(fw_desc)"

		# ---------------------------------------------------- 规则执法
		if fw_rules_present; then
			found=$(fw_rule_hits)
			if [ -n "$(echo $found)" ]; then
				hd_row ok "规则执法" "模板规则有实际命中（$(echo $found)），防火墙钩子在执行"
			else
				hd_row bad "规则执法" "规则已加载但计数恒 0 —— 内核可能根本没执行（QSDK 类固件加载正常却不拦）；点「检测规则是否生效」确认"
			fi
		else
			hd_row info "规则执法" "规则未加载，无需检测"
		fi

		# ---------------------------------------------------- NSS/ECM 加速
		if hd_ecm_present; then
			if hd_ecm_mod_loaded; then
				hd_row warn "NSS/ECM 加速" "ecm 模块在跑：QSDK 平台上它会绕过防火墙处理外部新连接，规则「已加载」也拦不住；可应用「关闭 NSS/ECM 加速」"
			else
				hd_row ok "NSS/ECM 加速" "已停用（防火墙执法不再被绕过）"
			fi
		fi

		# ---------------------------------------------------- include 健康
		found=$(fw_include_health)
		if [ -n "$(echo $found)" ]; then
			hd_row bad "include 健康" "firewall 里有问题的 include 段：$(echo $found) —— 值带引号会让 fw4 渲染崩溃（整机防火墙起不来），路径不存在是残留；建议删除"
		else
			hd_row ok "include 健康" "firewall 的 include 段没有异常"
		fi

		# ---------------------------------------------------- IPv6
		req=$(hd_ipv6_requesting)
		if [ -n "$req" ]; then
			hd_row bad "IPv6 请求" "接口 $req 正在向校园网要 IPv6 地址/前缀 —— 要前缀这个动作本身就等于声明「我是路由器」"
		else
			hd_row ok "IPv6 请求" "没有任何接口在请求 IPv6"
		fi

		if hd_ipv6_lan_global; then
			hd_row bad "内网 IPv6" "本机有全球 IPv6 地址；一旦拿到前缀，内网每台设备都会有一个，上游数地址就能数出你有几台设备"
		else
			hd_row ok "内网 IPv6" "没有全球 IPv6 地址"
		fi

		dev=$(wan_device)
		if [ -n "$dev" ]; then
			v=$(cat "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null)
			if [ "$v" = "1" ]; then
				hd_row ok "WAN 口 IPv6" "$dev 的 IPv6 已在内核层关闭"
			elif [ -n "$v" ]; then
				hd_row warn "WAN 口 IPv6" "$dev 的 IPv6 还开着，内核会往外发路由请求"
			fi
		fi

		if hd_svc_enabled odhcpd; then
			hd_row warn "odhcpd" "IPv6 地址/前缀服务还在跑，内网仍可能在发 RA"
		else
			hd_row ok "odhcpd" "已停用"
		fi

		# ---------------------------------------------------- 流量卸载
		v=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
		if [ "$v" = "1" ]; then
			hd_row bad "软件流量卸载" "已开启：已建立的连接会绕过 mangle 链，TTL 规则时对时不对，最容易出「有时被抓有时没事」"
		else
			hd_row ok "软件流量卸载" "已关闭"
		fi

		v=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
		if [ "$v" = "1" ]; then
			hd_row bad "硬件流量卸载" "已开启：数据包完全绕过 netfilter，防火墙规则对它无效"
		else
			hd_row ok "硬件流量卸载" "已关闭"
		fi

		if nft list ruleset 2>/dev/null | grep -q flowtable; then
			hd_row warn "卸载流表" "nft 规则集里还留着 flowtable"
		fi

		if hd_svc_enabled sqm; then
			hd_row warn "限速(SQM)" "SQM 会改写 TCP 参数，本身就是一个特征"
		fi

		# ---------------------------------------------------- TTL / MSS
		if hd_ttl_present; then
			hd_row ok "TTL 统一" "出网 TTL 已统一为 128（Windows 就是 128）"
		else
			hd_row warn "TTL 统一" "没找到 TTL 规则；转发出去的包 TTL 会是 63，上一跳一看就知道是 NAT"
		fi

		if hd_mss_present; then
			hd_row ok "MSS 统一" "TCP MSS 已钉死为 $HD_MSS"
		else
			hd_row info "MSS 统一" "未设置（可选，少一个差异）"
		fi

		# ---------------------------------------------------- DHCP 指纹
		dev=$(wan_iface)
		if [ -n "$dev" ]; then
			local host ven cid
			host=$(uci -q get "network.$dev.hostname" 2>/dev/null)
			ven=$(uci -q get "network.$dev.vendorid" 2>/dev/null)
			cid=$(uci -q get "network.$dev.clientid" 2>/dev/null)

			if [ "$ven" = "MSFT 5.0" ] && [ -n "$host" ] && [ -n "$cid" ]; then
				hd_row ok "DHCP 指纹" "主机名 $host / vendorid MSFT 5.0 / clientid 01+MAC —— 看起来像 Windows"
			else
				hd_row bad "DHCP 指纹" "主机名「${host:-空}」vendorid「${ven:-空}」clientid「${cid:-空}」—— 缺项会让上游一眼认出是路由器"
			fi

			if [ -n "$host" ]; then
				hd_row info "电脑身份" "当前叫 $host；只有被拉黑换 MAC 时才会跟着换，不换 MAC 就一直不变"
			fi
		fi

		# ---------------------------------------------------- 二层
		br=$(hd_wan_in_bridge)
		if [ -n "$br" ]; then
			hd_row bad "WAN 网桥" "WAN 口被桥进了 $br：二层直接暴露，DHCP Snooping / 端口 MAC 限制 / 组播泄漏都会变成真问题"
		else
			hd_row ok "WAN 网桥" "WAN 口不在任何网桥里"
		fi

		# ---------------------------------------------------- 定时联网
		found=""
		for s in $HD_QUIET_SVC; do
			hd_svc_enabled "$s" && found="$found $s"
		done
		if [ -n "$found" ]; then
			hd_row warn "定时联网服务" "还在跑：$(echo $found) —— 电脑不会定时往外发这些东西"
		else
			hd_row ok "定时联网服务" "没发现会定时往外发东西的服务"
		fi

		found=""
		for s in $HD_WATCH_SVC; do
			hd_svc_enabled "$s" && found="$found $s"
		done
		if [ -n "$found" ]; then
			hd_row info "隧道/代理类" "已装：$(echo $found) —— 这类工具大量外连，本身就很显眼，要单独排查"
		fi

		# ---------------------------------------------------- 路由协议 / 组播
		found=$(hd_route_found)
		if [ -n "$found" ]; then
			hd_row bad "路由协议" "在跑：$(echo $found) —— OSPF / RIP / BGP / PIM / IGMP 这类只有路由器会发，电脑一个都不发，是最响的警报"
		else
			hd_row ok "路由协议" "没有 OSPF / RIP / BGP / PIM / IGMP 这类守护进程在跑"
		fi

		found=$(hd_igmp_snoop_devs)
		if [ -n "$found" ]; then
			hd_row warn "IGMP 嗅探" "网桥 $(echo $found) 开着 IGMP 嗅探：路由器会自己往外发 IGMP 查询/报告，电脑不会"
		else
			hd_row ok "IGMP 嗅探" "网桥没有在往外发 IGMP"
		fi

		# ---------------------------------------------------- mDNS
		if ! hd_svc_exists "$HD_AVAHI_SVC" && ! hd_avahi_running; then
			hd_row ok "mDNS 外向宣告" "没装 avahi，不会有「主机名.local」从 WAN 跑出去"
		else
			v=$(hd_avahi_leak)
			if [ -n "$v" ]; then
				hn=$(uci -q get system.@system[0].hostname 2>/dev/null)
				[ -n "$hn" ] || hn=$(cat /proc/sys/kernel/hostname 2>/dev/null)
				[ -n "$hn" ] || hn="主机名"
				if [ "$v" = "all" ]; then
					hd_row bad "mDNS 外向宣告" "avahi 在所有网卡上响应 mDNS，WAN 也在内：上游能看到「$hn.local」，和你伪装的 LAPTOP-XXXX 对不上，是最容易被抓的矛盾点"
				else
					hd_row bad "mDNS 外向宣告" "avahi 还在 $v 上响应 mDNS：上游能看到「$hn.local」，和你伪装的 LAPTOP-XXXX 对不上"
				fi
			else
				hd_row ok "mDNS 外向宣告" "avahi 只在内网 $(hd_lan_ifaces) 上响应，WAN 上看不到主机名"
			fi
		fi

		# ---------------------------------------------------- 监听面
		found=$(hd_listen_wan_ports)
		case "$found" in
			'')
				hd_row ok "监听面" "管理界面 / DNS / NetBIOS 没有监听 WAN 侧地址"
				;;
			'?')
				hd_row info "监听面" "没有 netstat，无法检测 uhttpd / dnsmasq / nmbd 的监听地址"
				;;
			*)
				hd_row warn "监听面" "还听在所有地址 / WAN 地址上：$(echo $found) —— 现在靠防火墙挡着，规则一变就露；可应用「监听面收窄」"
				;;
		esac

		# ---------------------------------------------------- 孤儿物理口 IPv6
		found=$(hd_ports_scan | tr '\n' ' ')
		if [ -n "$(echo $found)" ]; then
			hd_row warn "物理口 IPv6" "未被任何接口使用的物理口$(echo $found)还开着 IPv6，fe80 的 MLD/DAD 可能漏到上游；可应用「物理口 IPv6 全关」"
		else
			hd_row ok "物理口 IPv6" "没有被 UCI 遗漏的物理口在发 IPv6"
		fi

		# ---------------------------------------------------- 单设备出网
		v=$(hd_single_dev_leaks)
		case "$v" in
			*'|'0)
				hd_row ok "单设备出网" "LAN 流量全部经本机重发或已 NAT，没有内网源地址直出"
				;;
			*)
				hd_row bad "单设备出网" "${v##*|} 条 LAN 流未经转换直出（$(echo ${v%%|*})）—— 上游能直接看到内网源地址，是最响的多设备信号"
				;;
		esac

		# ---------------------------------------------------- 各开关状态
		for grp in ipv6 offload sig routing quiet mdns listen ports ecm; do
			hd_row sw "$grp" "$(hd_flag "$grp")"
		done

		for grp in p2p remote stun nat4; do
			hd_row sw "$grp" "$(blk_flag "$grp" 2>/dev/null || echo 0)"
		done
		hd_row sw dhcp "$(uci -q get likepc.main.pc_fake 2>/dev/null | grep -q '^1$' && echo 1 || echo 0)"
	} >"$HD_REPORT" 2>/dev/null

	cat "$HD_REPORT"
	return 0
}

# ------------------------------------------------------------------ ① IPv6
hd_ipv6_kernel() {
	local d="$1"

	[ -n "$d" ] || return 0
	echo 0 >"/proc/sys/net/ipv6/conf/$d/router_solicitations" 2>/dev/null
	echo 0 >"/proc/sys/net/ipv6/conf/$d/accept_ra" 2>/dev/null
	echo 0 >"/proc/sys/net/ipv6/conf/$d/autoconf" 2>/dev/null
	echo 1 >"/proc/sys/net/ipv6/conf/$d/disable_ipv6" 2>/dev/null
	return 0
}

hd_hotplug_write() {
	mkdir -p "$(dirname "$HD_HOTPLUG")"

	cat >"$HD_HOTPLUG" <<'HDEOF'
#!/bin/sh
# 由 luci-app-likepc 写入：接口每次起来都禁掉 IPv6，避免内核往外发路由请求
[ "$ACTION" = "ifup" ] || exit 0
[ -n "$DEVICE" ] || exit 0
case "$DEVICE" in
	lo|br-lan|br-*) exit 0 ;;
esac
echo 0 > "/proc/sys/net/ipv6/conf/$DEVICE/router_solicitations" 2>/dev/null
echo 0 > "/proc/sys/net/ipv6/conf/$DEVICE/accept_ra" 2>/dev/null
echo 0 > "/proc/sys/net/ipv6/conf/$DEVICE/autoconf" 2>/dev/null
echo 1 > "/proc/sys/net/ipv6/conf/$DEVICE/disable_ipv6" 2>/dev/null
exit 0
HDEOF

	chmod 0755 "$HD_HOTPLUG" 2>/dev/null
	return 0
}

hd_ipv6() {
	local dev s p

	dev=$(wan_device)
	mkdir -p "$HD_DIR"

	hd_backup_file network
	hd_backup_file dhcp

	# 1) 所有接口都不再要 IPv6（地址和前缀都不要）
	for s in $(hd_ifaces); do
		p=$(uci -q get "network.$s.proto" 2>/dev/null)
		case "$p" in
			dhcpv6)
				log "接口 $s 是 IPv6 拨号，关掉它（不再请求前缀）"
				uci -q set "network.$s.proto=none"
				;;
			dhcp)
				uci -q delete "network.$s.ipv6"
				;;
		esac
	done

	# 2) 内网侧不再发 RA / DHCPv6 / NDP，也不下发前缀
	uci -q set dhcp.lan.ra=disabled
	uci -q set dhcp.lan.dhcpv6=disabled
	uci -q set dhcp.lan.ndp=disabled
	uci -q set dhcp.lan.master=0
	uci -q delete network.lan.ip6assign
	uci -q commit network
	uci -q commit dhcp

	# 3) 停掉 IPv6 服务
	hd_stop_svc odhcpd

	# 4) 内核层面：WAN 口不发路由请求、不收通告、整个关掉 IPv6
	hd_ipv6_kernel "$dev"

	# 5) 热插拔脚本，接口每次起来自动再来一遍
	hd_hotplug_write

	/etc/init.d/network reload >/dev/null 2>&1

	hd_on ipv6
	log "已关闭 IPv6：不再请求地址与前缀，内网不再发 RA，WAN(${dev:-未知}) 的 IPv6 已在内核层禁用"
	return 0
}

hd_ipv6_undo() {
	local dev

	dev=$(wan_device)

	if hd_restore_file network && hd_restore_file dhcp; then
		log "已还原 network / dhcp 配置（回到应用这项之前的样子）"
	else
		log "没找到 IPv6 的配置备份，只做最小恢复"
	fi

	hd_start_svc odhcpd
	rm -f "$HD_HOTPLUG"

	if [ -n "$dev" ]; then
		echo 0 >"/proc/sys/net/ipv6/conf/$dev/disable_ipv6" 2>/dev/null
	fi

	uci -q commit network 2>/dev/null
	uci -q commit dhcp 2>/dev/null
	/etc/init.d/network reload >/dev/null 2>&1

	hd_off ipv6
	log "已恢复 IPv6"
	return 0
}

# ------------------------------------------------------------------ ② 流量卸载
hd_offload() {
	mkdir -p "$HD_DIR"

	hd_backup_file firewall

	uci -q set firewall.@defaults[0].flow_offloading=0
	uci -q set firewall.@defaults[0].flow_offloading_hw=0
	uci -q commit firewall

	# 限速会改写 TCP 参数，一起停
	hd_svc_record_stop offload sqm

	/etc/init.d/firewall restart >/dev/null 2>&1

	hd_on offload
	log "已关闭流量卸载（软件 + 硬件）与限速：TTL、探针屏蔽这类规则从现在起才会真正生效"
	return 0
}

hd_offload_undo() {
	if hd_restore_file firewall; then
		log "已还原防火墙配置"
	fi

	hd_svc_restore offload
	/etc/init.d/firewall restart >/dev/null 2>&1

	hd_off offload
	log "已恢复流量卸载设置"
	return 0
}

# ------------------------------------------------------------------ ③ 出网特征统一
# firewall3：写成 include 脚本，由防火墙每次启动时执行（直接 iptables 会在 reload 后丢）
hd_fw3_write() {
	local need_ttl="$1"

	mkdir -p "$HD_DIR"

	{
		echo "#!/bin/sh"
		echo "# 由 luci-app-likepc 自动生成（出网特征统一），请勿手工修改"
		echo "# 由 /etc/config/firewall 的 include 段（type script）加载"
		if [ "$need_ttl" = "1" ]; then
			echo "iptables -t mangle -C POSTROUTING -j TTL --ttl-set 128 2>/dev/null ||"
			echo "	iptables -t mangle -A POSTROUTING -j TTL --ttl-set 128 2>/dev/null"
		fi
		echo "iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $HD_MSS 2>/dev/null ||"
		echo "	iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $HD_MSS 2>/dev/null"
		echo "exit 0"
	} >"$HD_FW3"

	chmod 0755 "$HD_FW3" 2>/dev/null
	return 0
}

hd_nft_write() {
	local need_ttl="$1"

	mkdir -p "$HD_DIR"

	{
		echo "# 由 luci-app-likepc 自动生成（出网特征统一），请勿手工修改"
		echo "# 本文件由 /etc/config/firewall 的 include 段加载，"
		echo "# 渲染时位于 table inet fw4 内部 —— 所以这里只定义 chain，不写 table。"
		if [ "$need_ttl" = "1" ]; then
			echo
			echo "chain likepc_hd_ttl {"
			echo "	type filter hook postrouting priority mangle; policy accept;"
			echo "	counter ip ttl set 128"
			echo "}"
		fi
		echo
		echo "chain likepc_hd_mss {"
		echo "	type filter hook postrouting priority mangle; policy accept;"
		echo "	counter tcp flags & (syn | rst) == syn tcp option maxseg size set $HD_MSS"
		echo "}"
	} >"$HD_NFT"

	return 0
}

hd_sig() {
	local need_ttl=1

	mkdir -p "$HD_DIR"

	if hd_main_ttl_present; then
		need_ttl=0
		log "TTL 统一已经生效（防火墙规则里带了），这一项只补 MSS"
	fi

	if [ "$(fw_version)" = "4" ]; then
		hd_nft_write "$need_ttl"
		hd_nft_include_add
	else
		hd_fw3_write "$need_ttl"
		hd_fw3_include_add
		[ "$need_ttl" = "1" ] && log "已把 TTL 统一写进加固规则（原防火墙规则里没有）"
	fi

	[ "$need_ttl" = "1" ] && hd_flag sig_ttl 1 || hd_flag sig_ttl 0

	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1

	hd_on sig
	log "已统一出网特征：TTL 128、TCP MSS $HD_MSS"
	return 0
}

hd_sig_undo() {
	local added

	added=$(hd_flag sig_ttl)

	if [ "$(fw_version)" = "4" ]; then
		hd_nft_include_del
		rm -f "$HD_NFT"
	else
		hd_fw3_include_del
		rm -f "$HD_FW3"

		# 兼容旧版本留下的直接 iptables 规则
		while iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$HD_MSS" 2>/dev/null; do :; done

		if [ "$added" = "1" ]; then
			while iptables -t mangle -D POSTROUTING -j TTL --ttl-set 128 2>/dev/null; do :; done
		fi
	fi

	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1

	hd_flag sig_ttl 0
	hd_off sig
	log "已撤销出网特征统一（主防火墙规则提供的那部分没动）"
	return 0
}

# ------------------------------------------------------------------ ④ DHCP 指纹
hd_dhcp() {
	load_config
	mac_pool_load

	pc_fake

	hd_on dhcp
	log "已伪装成 Windows 电脑（电脑名只在换 MAC 时才会跟着换）"
	return 0
}

hd_dhcp_undo() {
	load_config
	mac_pool_load

	pc_restore

	hd_flag dhcp 0
	log "已还原 WAN 原有 DHCP 参数"
	return 0
}

# ------------------------------------------------------------------ ⑤ 掐掉定时联网
hd_quiet() {
	local s

	mkdir -p "$HD_DIR"

	for s in $HD_QUIET_SVC; do
		hd_svc_record_stop quiet "$s"
	done

	hd_on quiet
	log "已停用所有会定时往外发东西的服务（撤销时会按名单恢复）"
	return 0
}

hd_quiet_undo() {
	hd_svc_restore quiet
	hd_off quiet
	log "已恢复被停用的服务"
	return 0
}

# ------------------------------------------------------------------ ⑥ 路由 / 组播协议
hd_routing() {
	local s v f

	mkdir -p "$HD_DIR"

	# 1) 在跑或开着自启的：停掉、取消自启，原来的启动状态记进名单
	for s in $(hd_route_found); do
		if hd_svc_enabled "$s"; then
			hd_svc_record_stop routing "$s"
		else
			killall "$s" >/dev/null 2>&1 && log "已结束路由/组播进程：$s"
		fi
	done

	# 2) 关掉网桥的 IGMP 嗅探（先记原值，撤销时照着还原）
	f="$HD_IGMP_FILE"
	for s in $(hd_igmp_snoop_devs); do
		v=$(uci -q get "network.$s.igmp_snooping" 2>/dev/null)
		grep -q "^$s|" "$f" 2>/dev/null || printf '%s|%s\n' "$s" "$v" >>"$f"
		uci -q set "network.$s.igmp_snooping=0"
		log "已关闭网桥 $s 的 IGMP 嗅探"
	done

	if [ -s "$f" ]; then
		uci -q commit network
		/etc/init.d/network reload >/dev/null 2>&1
	fi

	hd_on routing
	log "已关掉路由 / 组播协议（撤销时按名单恢复原来开着的那些）"
	return 0
}

hd_routing_undo() {
	local f s v

	hd_svc_restore routing

	f="$HD_IGMP_FILE"
	if [ -s "$f" ]; then
		while IFS='|' read -r s v; do
			[ -n "$s" ] || continue
			if [ -n "$v" ]; then
				uci -q set "network.$s.igmp_snooping=$v"
			else
				uci -q delete "network.$s.igmp_snooping"
			fi
		done <"$f"
		rm -f "$f"
		uci -q commit network
		/etc/init.d/network reload >/dev/null 2>&1
	fi

	hd_off routing
	log "已恢复路由 / 组播相关设置"
	return 0
}

# ------------------------------------------------------------------ ⑦ mDNS 外泄
# avahi 默认在每一块网卡上响应 mDNS（含 WAN）。处理方式：把 allow-interfaces
# 限制成内网网桥 —— 内网的 .local 自动发现照常，WAN 上不再宣告主机名。
# 配置改不动、或者改完起不来时，退化成「停用 + 取消自启」，撤销时按名单恢复。

hd_mdns_conf_write() {
	local lan tmp

	lan="$1"
	tmp="$HD_AVAHI_CONF.likepc"

	if grep -q '^\[server\]' "$HD_AVAHI_CONF" 2>/dev/null; then
		awk -v lan="$lan" '
			/^\[server\][[:space:]]*$/ { print; print "allow-interfaces=" lan; done = 1; next }
			/^[[:space:]]*allow-interfaces[[:space:]]*=/ { next }
			{ print }
			END { if (!done) print "allow-interfaces=" lan }
		' "$HD_AVAHI_CONF" >"$tmp" 2>/dev/null
	else
		{
			echo "[server]"
			echo "allow-interfaces=$lan"
			grep -v '^[[:space:]]*allow-interfaces[[:space:]]*=' "$HD_AVAHI_CONF" 2>/dev/null
		} >"$tmp"
	fi

	[ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
	mv "$tmp" "$HD_AVAHI_CONF" 2>/dev/null || { rm -f "$tmp"; return 1; }
	return 0
}

hd_mdns_stop() {
	if hd_svc_exists "$HD_AVAHI_SVC"; then
		if hd_svc_enabled "$HD_AVAHI_SVC"; then
			hd_svc_record_stop mdns "$HD_AVAHI_SVC"
		else
			hd_stop_svc "$HD_AVAHI_SVC"
		fi
	else
		killall avahi-daemon >/dev/null 2>&1
	fi

	hd_on mdns
	log "avahi 配置改不动，已直接停用它（内网的 .local 自动发现也会一起停）"
	return 0
}

hd_mdns() {
	local lan allow was

	mkdir -p "$HD_DIR"

	if ! hd_svc_exists "$HD_AVAHI_SVC" && ! hd_avahi_running; then
		hd_on mdns
		log "没装 avahi，mDNS 本来就不会往外宣告，跳过"
		return 0
	fi

	lan=$(hd_lan_ifaces)
	allow=$(hd_avahi_allow | tr -d ' ')

	if [ -n "$allow" ] && [ "$allow" = "$lan" ] && hd_avahi_running; then
		hd_on mdns
		log "mDNS 已经只在内网 $lan 上响应，无需重复处理"
		return 0
	fi

	was=0
	hd_avahi_running && was=1

	if [ ! -f "$HD_AVAHI_CONF" ]; then
		hd_mdns_stop
		return 0
	fi

	[ -f "$HD_BAK/avahi-daemon.conf" ] || {
		mkdir -p "$HD_BAK"
		cp "$HD_AVAHI_CONF" "$HD_BAK/avahi-daemon.conf" 2>/dev/null
	}

	if ! hd_mdns_conf_write "$lan" || [ "$(hd_avahi_allow | tr -d ' ')" != "$lan" ]; then
		hd_mdns_stop
		return 0
	fi

	if [ "$was" != "1" ]; then
		hd_on mdns
		log "已把 mDNS 限制在内网 $lan（服务当前没在跑，下次启动生效）"
		return 0
	fi

	"$HD_INITD/$HD_AVAHI_SVC" restart >/dev/null 2>&1
	sleep 1

	if ! hd_avahi_running; then
		cp "$HD_BAK/avahi-daemon.conf" "$HD_AVAHI_CONF" 2>/dev/null
		hd_mdns_stop
		return 0
	fi

	hd_on mdns
	log "已把 mDNS 限制在内网 $lan：WAN 上不再宣告主机名"
	return 0
}

hd_mdns_undo() {
	hd_svc_restore mdns

	if [ -f "$HD_BAK/avahi-daemon.conf" ]; then
		cp "$HD_BAK/avahi-daemon.conf" "$HD_AVAHI_CONF" 2>/dev/null
		rm -f "$HD_BAK/avahi-daemon.conf"
	elif [ -f "$HD_AVAHI_CONF" ]; then
		sed -i '/^[[:space:]]*allow-interfaces[[:space:]]*=/d' "$HD_AVAHI_CONF" 2>/dev/null
	fi

	if hd_svc_exists "$HD_AVAHI_SVC" && hd_avahi_running; then
		"$HD_INITD/$HD_AVAHI_SVC" restart >/dev/null 2>&1
	fi

	hd_off mdns
	log "已恢复 mDNS 设置"
	return 0
}

# ------------------------------------------------------------------ ⑧ 监听面收窄
# uhttpd 的 80/443、dnsmasq 的 53、nmbd 的 137/138 默认都听在所有地址（0.0.0.0）上，
# 平时全靠 wan 区的 REJECT 挡着 —— 防火墙规则一变就直接暴露。这里把它们收窄到内网：
#   uhttpd  -> 只监听内网 IP（端口沿用原来的）
#   dnsmasq -> notinterface 掉 WAN（接口名和设备名都写，两种解析方式都盖住）
#   nmbd    -> samba 限到内网；配置改不动 / 改完还绑 0.0.0.0 时退化成停用
# 只动监听地址，不改防火墙规则，两层各管各的；撤销时按记录还原。

HD_LISTEN_UHTTPD="$HD_DIR/hd-listen-uhttpd"
HD_LISTEN_DNS="$HD_DIR/hd-listen-dns"
HD_LISTEN_SAMBA="$HD_DIR/hd-listen-samba"

# 服务在跑或开着自启才 restart，别把用户停着的服务顺手拉起来
hd_maybe_restart() {
	local svc="$1" pids="$2" p run=0

	hd_svc_exists "$svc" || return 0
	hd_svc_enabled "$svc" && run=1
	for p in $pids; do
		pidof "$p" >/dev/null 2>&1 && run=1
	done

	[ "$run" = "1" ] && "$HD_INITD/$svc" restart >/dev/null 2>&1
	return 0
}

# 内网 IP：复用 fw.sh 的算法（界面手动覆盖 > network.lan > 兜底）
hd_listen_lan_ip() {
	fw_lan_info 2>/dev/null
	echo "${FW_ROUTER_IP:-192.168.1.1}"
}

# '0.0.0.0:80' / '[::]:443' -> '80'
hd_listen_port_of() {
	echo "${1##*:}"
}

hd_listen_uhttpd() {
	local ip="$1" e p hports tports

	[ -f "$HD_CONF_DIR/uhttpd" ] || {
		log "没找到 /etc/config/uhttpd，跳过管理界面部分"
		return 0
	}

	# 原监听地址记档，撤销时按记录还原
	{
		for e in $(uci -q get uhttpd.main.listen_http 2>/dev/null); do echo "http|$e"; done
		for e in $(uci -q get uhttpd.main.listen_https 2>/dev/null); do echo "https|$e"; done
	} >"$HD_LISTEN_UHTTPD" 2>/dev/null

	hports=""
	for e in $(uci -q get uhttpd.main.listen_http 2>/dev/null); do
		p=$(hd_listen_port_of "$e")
		case " $hports " in *" $p "*) ;; *) hports="$hports $p" ;; esac
	done
	tports=""
	for e in $(uci -q get uhttpd.main.listen_https 2>/dev/null); do
		p=$(hd_listen_port_of "$e")
		case " $tports " in *" $p "*) ;; *) tports="$tports $p" ;; esac
	done
	[ -n "$(echo $hports)" ] || hports="80"
	[ -n "$(echo $tports)" ] || tports="443"

	uci -q delete uhttpd.main.listen_http
	uci -q delete uhttpd.main.listen_https
	for p in $hports; do uci -q add_list uhttpd.main.listen_http="$ip:$p"; done
	for p in $tports; do uci -q add_list uhttpd.main.listen_https="$ip:$p"; done
	uci -q commit uhttpd

	log "管理界面已改为只监听内网 ${ip}（http:$(echo $hports | tr ' ' ',') / https:$(echo $tports | tr ' ' ',')）"
	log "提醒：以后要改内网网段，先撤销这一项，否则后台会打不开"

	# restart 会断掉当前 LuCI 连接，调用方把它放在最后一步
	hd_maybe_restart uhttpd uhttpd
	return 0
}

hd_listen_uhttpd_undo() {
	local kind addr

	[ -f "$HD_LISTEN_UHTTPD" ] || return 0

	uci -q delete uhttpd.main.listen_http
	uci -q delete uhttpd.main.listen_https

	while IFS='|' read -r kind addr; do
		[ -n "$addr" ] || continue
		case "$kind" in
			http)  uci -q add_list uhttpd.main.listen_http="$addr" ;;
			https) uci -q add_list uhttpd.main.listen_https="$addr" ;;
		esac
	done <"$HD_LISTEN_UHTTPD"
	rm -f "$HD_LISTEN_UHTTPD"

	uci -q commit uhttpd
	hd_maybe_restart uhttpd uhttpd
	log "管理界面监听地址已还原"
	return 0
}

hd_listen_dns() {
	local wanif wandev names

	wanif=$(wan_iface)
	wandev=$(wan_device)
	[ -n "$wanif$wandev" ] || {
		log "识别不到 WAN 接口，跳过 dnsmasq 部分"
		return 0
	}

	names="$wanif"
	if [ -n "$wandev" ] && [ "$wandev" != "$wanif" ]; then
		names="$names $wandev"
	fi
	echo "$names" >"$HD_LISTEN_DNS"

	for wanif in $names; do
		uci -q del_list dhcp.@dnsmasq[0].notinterface="$wanif"
		uci -q add_list dhcp.@dnsmasq[0].notinterface="$wanif"
	done
	uci -q commit dhcp

	hd_maybe_restart dnsmasq dnsmasq
	log "dnsmasq 已不再监听 WAN（notinterface：$(echo $names)）"
	return 0
}

hd_listen_dns_undo() {
	local name

	[ -f "$HD_LISTEN_DNS" ] || return 0

	while read -r name; do
		[ -n "$name" ] || continue
		uci -q del_list dhcp.@dnsmasq[0].notinterface="$name"
	done <"$HD_LISTEN_DNS"
	rm -f "$HD_LISTEN_DNS"

	uci -q commit dhcp
	hd_maybe_restart dnsmasq dnsmasq
	log "dnsmasq 监听已还原"
	return 0
}

hd_listen_samba() {
	local svc v n

	if hd_svc_exists samba4; then
		svc=samba4
	elif hd_svc_exists samba; then
		svc=samba
	else
		if pidof nmbd >/dev/null 2>&1; then
			killall nmbd >/dev/null 2>&1
			log "nmbd 在跑但没有对应服务脚本，已直接结束（不持久，重启后请自行处理）"
		else
			log "没装 samba（nmbd），跳过 NetBIOS 部分"
		fi
		return 0
	fi

	# 老版 samba / 没有配置文件时改不了，退化成停用整个服务（按名单恢复）
	if [ "$svc" != "samba4" ] || [ ! -f "$HD_CONF_DIR/samba4" ]; then
		hd_svc_record_stop listen "$svc"
		log "samba（$svc）没有可改的配置，已停用整个服务（137/138 不再监听；撤销时按名单恢复）"
		return 0
	fi

	v=$(uci -q get samba4.@samba[0].interface 2>/dev/null)
	n=$(uci -q get samba4.@samba[0].disable_netbios 2>/dev/null)
	{
		echo "interface=$v"
		echo "disable_netbios=$n"
	} >"$HD_LISTEN_SAMBA"

	uci -q set samba4.@samba[0].interface='lan'
	# interface=lan + bind interfaces only 约束不了 nmbd 的 137/138 通配绑定，
	# 直接不启动它（init 脚本原生支持）；内网按 IP / DNS 名访问共享不受影响
	uci -q set samba4.@samba[0].disable_netbios='1'
	uci -q commit samba4
	hd_maybe_restart "$svc" "smbd nmbd"

	if pidof nmbd >/dev/null 2>&1; then
		if netstat -lnu 2>/dev/null | grep -q ' 0\.0\.0\.0:137 '; then
			log "samba 限内网后 nmbd 仍绑 0.0.0.0:137，退化成停用整个 samba（文件共享一并停；撤销时恢复）"
			hd_svc_record_stop listen "$svc"
			return 0
		fi
		log "samba/nmbd 已限制在内网（137/138 不再绑所有地址）"
	else
		log "samba 已限内网并停用 NetBIOS（nmbd 不再启动；445 文件共享不受影响）"
	fi

	return 0
}

hd_listen_samba_undo() {
	local svc v n

	hd_svc_restore listen

	if [ -f "$HD_LISTEN_SAMBA" ]; then
		v=$(sed -n 's/^interface=//p' "$HD_LISTEN_SAMBA")
		n=$(sed -n 's/^disable_netbios=//p' "$HD_LISTEN_SAMBA")
		if [ -n "$v" ]; then
			uci -q set samba4.@samba[0].interface="$v"
		else
			uci -q delete samba4.@samba[0].interface 2>/dev/null
		fi
		if [ -n "$n" ]; then
			uci -q set samba4.@samba[0].disable_netbios="$n"
		else
			uci -q delete samba4.@samba[0].disable_netbios 2>/dev/null
		fi
		rm -f "$HD_LISTEN_SAMBA"
		uci -q commit samba4
	fi

	if hd_svc_exists samba4; then
		svc=samba4
	else
		svc=samba
	fi
	hd_maybe_restart "$svc" "smbd nmbd"

	log "samba/nmbd 监听设置已还原"
	return 0
}

hd_listen() {
	local ip

	# 防重入：再点一次会把「已收窄的值」记成原始值，撤销就还原不回去了
	if [ "$(hd_flag listen)" = "1" ]; then
		log "监听面已处于收窄状态；要重新应用请先撤销"
		return 0
	fi

	mkdir -p "$HD_DIR"

	ip=$(hd_listen_lan_ip)

	hd_listen_dns
	hd_listen_samba
	hd_listen_vsftpd "$ip"
	hd_listen_extra_svcs
	hd_listen_ksmbd_note

	# uhttpd 放最后：restart 会断掉当前 LuCI 连接，页面可能要刷新一次
	hd_listen_uhttpd "$ip"

	hd_on listen
	log "监听面已收窄到内网（管理界面 / DNS / NetBIOS / FTP）；防火墙那层 REJECT 仍建议保留，两层互不替代"
	return 0
}

hd_listen_undo() {
	hd_listen_dns_undo
	hd_listen_samba_undo
	hd_listen_vsftpd_undo
	hd_listen_uhttpd_undo

	hd_off listen
	log "监听面已还原（uhttpd / dnsmasq / samba / vsftpd 及停用的服务）"
	return 0
}

# ---------------------------------------------------------- 监听面扩员
# vsftpd / wsdd2 / xl2tpd / ksmbd：QSDK 类固件上常见、默认全听 0.0.0.0 的服务
HD_LISTEN_VSFTPD="$HD_DIR/hd-listen-vsftpd"

hd_listen_vsftpd() {
	local ip="$1"

	[ -f "$HD_CONF_DIR/vsftpd" ] || {
		log "没装 vsftpd，跳过 FTP 部分"
		return 0
	}
	uci -q get vsftpd.listen.ipv4 >/dev/null 2>&1 || {
		log "vsftpd 配置里没有 listen.ipv4 项，跳过 FTP 部分"
		return 0
	}

	uci -q get vsftpd.listen.ipv4 >"$HD_LISTEN_VSFTPD" 2>/dev/null
	uci set vsftpd.listen.ipv4="$ip"
	uci commit vsftpd
	hd_maybe_restart vsftpd vsftpd
	log "vsftpd 已只监听内网 $ip（21 端口不再对所有地址开放）"
	return 0
}

hd_listen_vsftpd_undo() {
	local v

	[ -f "$HD_LISTEN_VSFTPD" ] || return 0
	v=$(cat "$HD_LISTEN_VSFTPD")
	if [ -n "$v" ]; then
		uci set vsftpd.listen.ipv4="$v"
	else
		uci -q delete vsftpd.listen.ipv4 2>/dev/null
	fi
	rm -f "$HD_LISTEN_VSFTPD"
	uci commit vsftpd
	hd_maybe_restart vsftpd vsftpd
	return 0
}

# wsdd2（WSD/LLMNR 发现，3702/5355）和闲置的 xl2tpd（1701）：停掉，按名单恢复
hd_listen_extra_svcs() {
	if hd_svc_exists wsdd2; then
		hd_svc_record_stop listen wsdd2
	fi

	if hd_svc_exists xl2tpd; then
		# 有配置文件或在跑 L2TP 拨号的机器说明真在用，不动
		if [ -f "$HD_CONF_DIR/xl2tpd" ] || uci -q show network 2>/dev/null | grep -q "proto='l2tp"; then
			log "检测到 L2TP 在用（有配置 / l2tp 接口），xl2tpd 不动"
		else
			hd_svc_record_stop listen xl2tpd
		fi
	fi

	return 0
}

# ksmbd（内核态 SMB）：多数构建的 interface 选项约束不了它的绑定，只能点名
hd_listen_ksmbd_note() {
	hd_svc_exists ksmbd || return 0

	if netstat -lnt 2>/dev/null | grep -qE "0\.0\.0\.0:445|:::445"; then
		log "注意：ksmbd 仍监听所有地址的 445（interface 选项在这个构建上约束不了它）"
		log "不用文件共享就停用它：/etc/init.d/ksmbd disable && /etc/init.d/ksmbd stop"
	fi

	return 0
}

# 体检用：哪些服务端口还听在「所有地址」或 WAN 地址上（0.0.0.0 / [::] 都算）
hd_listen_wan_ports() {
	local dev ip p found=""

	command -v netstat >/dev/null 2>&1 || { echo "?"; return 0; }

	dev=$(wan_device)
	ip=""
	[ -n "$dev" ] && ip=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)

	for p in 53 80 443 137 138; do
		if netstat -ln 2>/dev/null | grep -q "0\.0\.0\.0:$p " \
			|| netstat -ln 2>/dev/null | grep -q "\[::\]:$p " \
			|| { [ -n "$ip" ] && netstat -ln 2>/dev/null | grep -q " $ip:$p "; }; then
			case "$p" in
				80|443) found="$found ${p}(管理界面)" ;;
				53)     found="$found ${p}(DNS)" ;;
				*)      found="$found ${p}(NetBIOS)" ;;
			esac
		fi
	done

	echo "$found"
	return 0
}

# ------------------------------------------------------------------ ⑨ 物理口 IPv6
# 「IPv6 全关」关的是 UCI 接口和 WAN 设备；DSA 主口（eth0）这类不被 UCI 管理的
# 物理口不在它的名单里 —— fe80 链路本地地址还在，载波起来时 MLD/DAD 仍会往外发，
# 上游在广播域里能看到第二个 MAC。这一项专门补这个盲区：
#   网桥（br-*）、无线、任何被 interface/device 段占用的设备一律不碰，
#   只关「孤儿物理口」，重启后由 sysctl / 热插拔自动保持。

HD_PORTS_LIST="$HD_DIR/hd-ports-devs"
HD_PORTS_SYSCTL=/etc/sysctl.d/99-likepc-ports.conf
HD_PORTS_HOTPLUG=/etc/hotplug.d/iface/99-likepc-ports

# 某设备是否是任何一个网桥的成员
hd_ports_in_bridge() {
	local d

	for d in /sys/class/net/*; do
		[ -e "$d/brif/$1" ] && return 0
	done

	return 1
}

# 被 network 配置（interface / device 段）占用的设备名
hd_ports_used() {
	local s v out=""

	for s in $(uci -q show network 2>/dev/null | grep -E '=interface$|=device$' | cut -d. -f2 | cut -d= -f1); do
		for v in $(uci -q get "network.$s.device" 2>/dev/null) \
			$(uci -q get "network.$s.ifname" 2>/dev/null) \
			$(uci -q get "network.$s.name" 2>/dev/null) \
			$(uci -q get "network.$s.ports" 2>/dev/null); do
			case " $out " in
				*" $v "*) ;;
				*) out="$out $v" ;;
			esac
		done
	done

	echo "$out $(wan_device 2>/dev/null)"
	return 0
}

# 找出 IPv6 还开着的「孤儿物理口」（跳过已关掉的，天然幂等）
hd_ports_scan() {
	local p d used dis

	used=$(hd_ports_used)

	for p in /sys/class/net/*; do
		[ -d "$p" ] || continue
		d=${p##*/}

		case "$d" in
			lo|br-*|wlan*|ra*|ath*|apcli*|wds*|ppp*|tun*|tap*|wg*|sit*|ip6tnl*|ipip*|gre*|gretap*|veth*|ifb*|teql*|dummy*|macvlan*|macvtap*)
				continue ;;
		esac

		case " $used " in
			*" $d "*) continue ;;
		esac

		hd_ports_in_bridge "$d" && continue

		dis=$(cat "/proc/sys/net/ipv6/conf/$d/disable_ipv6" 2>/dev/null)
		[ -n "$dis" ] || continue
		[ "$dis" = "1" ] || echo "$d"
	done

	return 0
}

hd_ports_sysctl_write() {
	local d

	mkdir -p /etc/sysctl.d

	{
		echo "# 由 luci-app-likepc 自动生成（物理口 IPv6），撤销时会删除本文件"
		while IFS='|' read -r d _rs _ra _au _dis; do
			[ -n "$d" ] || continue
			# 带点的接口名（eth0.1 之类）busybox sysctl 解析不了，交给热插拔兜底
			case "$d" in *.*) continue ;; esac
			echo "net.ipv6.conf.$d.disable_ipv6=1"
		done <"$HD_PORTS_LIST"
	} >"$HD_PORTS_SYSCTL"

	return 0
}

hd_ports_hotplug_write() {
	mkdir -p "$(dirname "$HD_PORTS_HOTPLUG")"

	cat >"$HD_PORTS_HOTPLUG" <<'HDEOF'
#!/bin/sh
# 由 luci-app-likepc 写入：接口起来时把名单里物理口的 IPv6 再压一遍（幂等）
[ "$ACTION" = ifup ] || exit 0
f=/etc/likepc/hd-ports-devs
[ -f "$f" ] || exit 0
while IFS='|' read -r d _x; do
	case "$d" in ''|*[!a-zA-Z0-9._-]*) continue ;; esac
	[ -e "/proc/sys/net/ipv6/conf/$d" ] || continue
	echo 1 > "/proc/sys/net/ipv6/conf/$d/disable_ipv6" 2>/dev/null
done <"$f"
exit 0
HDEOF

	chmod 0755 "$HD_PORTS_HOTPLUG" 2>/dev/null
	return 0
}

hd_ports() {
	local d rs ra au dis changed=""

	mkdir -p "$HD_DIR"

	# 之前应用过：沿用上次的名单压一遍，不覆盖记录
	if [ -s "$HD_PORTS_LIST" ]; then
		while IFS='|' read -r d _rs _ra _au _dis; do
			[ -n "$d" ] || continue
			hd_ipv6_kernel "$d"
		done <"$HD_PORTS_LIST"

		hd_ports_sysctl_write
		hd_ports_hotplug_write
		hd_on ports
		log "物理口 IPv6 已在关闭状态（按上次记录重新压了一遍）"
		return 0
	fi

	for d in $(hd_ports_scan); do
		rs=$(cat "/proc/sys/net/ipv6/conf/$d/router_solicitations" 2>/dev/null)
		ra=$(cat "/proc/sys/net/ipv6/conf/$d/accept_ra" 2>/dev/null)
		au=$(cat "/proc/sys/net/ipv6/conf/$d/autoconf" 2>/dev/null)
		dis=$(cat "/proc/sys/net/ipv6/conf/$d/disable_ipv6" 2>/dev/null)
		printf '%s|%s|%s|%s|%s\n' "$d" "$rs" "$ra" "$au" "$dis" >>"$HD_PORTS_LIST"

		hd_ipv6_kernel "$d"
		changed="$changed $d"
	done

	if [ -z "$changed" ]; then
		rm -f "$HD_PORTS_LIST"
		hd_on ports
		log "没找到需要补关 IPv6 的物理口（网桥 / 无线 / 被接口用到的都跳过了）"
		return 0
	fi

	hd_ports_sysctl_write
	hd_ports_hotplug_write

	hd_on ports
	log "已关掉物理口$(echo $changed) 的 IPv6（重启后由 sysctl / 热插拔自动保持）"
	return 0
}

hd_ports_undo() {
	local d rs ra au dis

	if [ -f "$HD_PORTS_LIST" ]; then
		while IFS='|' read -r d rs ra au dis; do
			[ -n "$d" ] || continue
			[ -e "/proc/sys/net/ipv6/conf/$d" ] || continue

			[ -z "$rs" ] || echo "$rs" >"/proc/sys/net/ipv6/conf/$d/router_solicitations" 2>/dev/null
			[ -z "$ra" ] || echo "$ra" >"/proc/sys/net/ipv6/conf/$d/accept_ra" 2>/dev/null
			[ -z "$au" ] || echo "$au" >"/proc/sys/net/ipv6/conf/$d/autoconf" 2>/dev/null
			[ -z "$dis" ] || echo "$dis" >"/proc/sys/net/ipv6/conf/$d/disable_ipv6" 2>/dev/null
		done <"$HD_PORTS_LIST"
		rm -f "$HD_PORTS_LIST"
	fi

	rm -f "$HD_PORTS_SYSCTL" "$HD_PORTS_HOTPLUG"

	hd_off ports
	log "已按记录还原物理口的 IPv6 参数"
	return 0
}

# ------------------------------------------------------------------ ⑩ NSS/ECM 加速
# QSDK 平台的 NSS/ECM 加速会在 netfilter 之前处理外部新发起的连接：
# 防火墙规则「已加载」但一条都拦不住（fwprobe 可以证实，实测于 QSDK 固件）。
# 这一项目前只有 QSDK 类固件才有：停掉 qca-nss-ecm 服务并卸载 ecm 模块，
# 让数据路径回落内核协议栈，防火墙恢复执法。WiFi 依赖的 nss_drv 不动。
# 全量走本机代理（ua3f 一类）的机器上，性能损失接近零 —— NSS 加速的是
# 转发路径，本机代理流量本来就不经过它。

HD_ECM_SVC=qca-nss-ecm
HD_ECM_MOD=ecm

hd_ecm_mod_loaded() {
	lsmod 2>/dev/null | grep -q "^$HD_ECM_MOD "
}

hd_ecm_present() {
	hd_svc_exists "$HD_ECM_SVC" || hd_ecm_mod_loaded
}

hd_ecm() {
	if ! hd_ecm_present; then
		hd_on ecm
		log "没装 NSS/ECM（非 QSDK 平台），不需要处理"
		return 0
	fi

	mkdir -p "$HD_DIR"

	# 服务停掉 + 取消自启（原启动状态记名单，撤销时恢复）
	if hd_svc_exists "$HD_ECM_SVC"; then
		hd_svc_record_stop ecm "$HD_ECM_SVC"
	fi

	# 服务停了模块还在就手动卸载（WiFi 依赖的 nss_drv 不碰）
	if hd_ecm_mod_loaded; then
		if rmmod "$HD_ECM_MOD" 2>/dev/null; then
			log "已卸载 ecm 内核模块，数据路径回落内核协议栈"
		else
			log "rmmod ecm 失败（模块被占用）—— 服务已停，重启后不会再加载"
		fi
	fi

	hd_on ecm
	log "已关闭 NSS/ECM 加速：外部新连接现在会经过防火墙（点「检测规则是否生效」验证）"
	return 0
}

hd_ecm_undo() {
	hd_svc_restore ecm

	if hd_svc_exists "$HD_ECM_SVC" && ! hd_ecm_mod_loaded; then
		"$HD_INITD/$HD_ECM_SVC" start >/dev/null 2>&1
	fi

	hd_off ecm
	log "已恢复 NSS/ECM 加速（服务/模块重新加载，防火墙执法会再次被绕过）"
	return 0
}