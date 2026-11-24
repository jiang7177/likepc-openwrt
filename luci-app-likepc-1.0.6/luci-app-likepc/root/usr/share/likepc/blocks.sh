#!/bin/sh
# 流量拦截（对局域网所有设备生效）
# 由 likepc.sh source，不单独运行
#
# 四组互相独立的开关，每组一对「应用 / 撤销」：
#   blk_p2p     BT / eMule / 迅雷 这类下载器的默认端口
#   blk_remote  RustDesk / TeamViewer / AnyDesk / VNC 这类远程控制
#   blk_stun    STUN / TURN（WebRTC、NAT 类型探测）
#   blk_nat4    强制对称 NAT（masquerade random,fully-random）—— 让打洞失效
#
# 只作用于「内网 -> WAN」的转发，路由器自己发起的流量不受影响。
# 端口清单故意写死成白名单式，不开放自定义大范围：27015-27050 / 3074 /
# 3478-3480 之外的常用游戏端口（5000-5500、Discord 随机高位 UDP）一律不碰。

BLK_DIR=${BLK_DIR:-/etc/likepc}
BLK_NFT=${BLK_NFT:-/etc/likepc/blocks.nft}
BLK_FW3=${BLK_FW3:-/etc/likepc/blocks.sh}

# 下载器默认端口：BitTorrent / uTorrent(2710) / 迅雷(3076-3078) / eMule(4661-4672) / Transmission(51413)
BLK_P2P_TCP="2710 3076-3078 4661-4662 4672 6881-6999 16881 51413"
BLK_P2P_UDP="2710 3076-3078 4672 6881-6999 16881 51413"

# 远程控制：VNC(5900-5901) / TeamViewer(5938) / AnyDesk(6568) / RustDesk(21115-21119)
BLK_REMOTE_TCP="5900-5901 5938 21115-21119"
BLK_REMOTE_UDP="5938 6568 21116"

# STUN / TURN：3478-3479 标准、5349 TLS、19302-19309 Google
BLK_STUN_TCP="3478-3479 5349"
BLK_STUN_UDP="3478-3479 5349 19302-19309"

blk_flag() {
	local name="$1" val="$2"

	if [ -n "$val" ]; then
		mkdir -p "$BLK_DIR"
		echo "$val" >"$BLK_DIR/blk-$name" 2>/dev/null
		return 0
	fi

	local v
	v=$(cat "$BLK_DIR/blk-$name" 2>/dev/null)
	[ -n "$v" ] || v=0
	echo "$v"
	return 0
}

blk_on() { blk_flag "$1" 1; }
blk_off() { blk_flag "$1" 0; }

# 一组端口写成 nft 集合的样子：2710 3076-3078 -> 2710, 3076-3078
blk_set() {
	echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/, /g'
}

blk_wan() {
	local d
	d=$(wan_device 2>/dev/null)
	[ -n "$d" ] || d=wan
	echo "$d"
}

blk_lan() {
	hd_lan_ifaces | cut -d, -f1
}

blk_any_forward() {
	[ "$(blk_flag p2p)" = "1" ] && return 0
	[ "$(blk_flag remote)" = "1" ] && return 0
	[ "$(blk_flag stun)" = "1" ] && return 0
	return 1
}

blk_any() {
	blk_any_forward && return 0
	[ "$(blk_flag nat4)" = "1" ] && return 0
	return 1
}

blk_render_nft() {
	local wan lan out

	out="$1"
	[ -n "$out" ] || out="$BLK_NFT"

	wan=$(blk_wan)
	lan=$(blk_lan)

	mkdir -p "$BLK_DIR"

	{
		echo "# 由 luci-app-likepc 自动生成（流量拦截），请勿手工修改"
		echo "# 内网($lan) -> WAN($wan)；渲染时位于 table inet fw4 内部，只定义 chain"

		if blk_any_forward; then
			echo
			echo "chain likepc_blk {"
			echo "	type filter hook forward priority -1; policy accept;"
			if [ "$(blk_flag p2p)" = "1" ]; then
				echo "	iifname \"$lan\" oifname \"$wan\" tcp dport { $(blk_set "$BLK_P2P_TCP") } counter drop"
				echo "	iifname \"$lan\" oifname \"$wan\" udp dport { $(blk_set "$BLK_P2P_UDP") } counter drop"
			fi
			if [ "$(blk_flag remote)" = "1" ]; then
				echo "	iifname \"$lan\" oifname \"$wan\" tcp dport { $(blk_set "$BLK_REMOTE_TCP") } counter drop"
				echo "	iifname \"$lan\" oifname \"$wan\" udp dport { $(blk_set "$BLK_REMOTE_UDP") } counter drop"
			fi
			if [ "$(blk_flag stun)" = "1" ]; then
				echo "	iifname \"$lan\" oifname \"$wan\" tcp dport { $(blk_set "$BLK_STUN_TCP") } counter drop"
				echo "	iifname \"$lan\" oifname \"$wan\" udp dport { $(blk_set "$BLK_STUN_UDP") } counter drop"
			fi
			echo "}"
		fi

		if [ "$(blk_flag nat4)" = "1" ]; then
			echo
			echo "chain likepc_blk_nat {"
			echo "	type nat hook postrouting priority 99; policy accept;"
			echo "	oifname \"$wan\" meta nfproto ipv4 masquerade random,fully-random"
			echo "}"
		fi
	} >"$out"

	return 0
}

# 先用 nft -c 校验，语法不对就不装，避免把整个防火墙搞挂
blk_validate_nft() {
	local src="$1" tmp="/tmp/likepc-blk-check.nft"

	command -v nft >/dev/null 2>&1 || return 0

	{
		echo "table inet likepc_check {"
		cat "$src"
		echo "}"
	} >"$tmp" 2>/dev/null

	if nft -c -f "$tmp" >/dev/null 2>&1; then
		rm -f "$tmp"
		return 0
	fi

	rm -f "$tmp"
	return 1
}

blk_render_fw3() {
	local wan lan

	wan=$(blk_wan)
	lan=$(blk_lan)

	mkdir -p "$BLK_DIR"

	{
		echo "#!/bin/sh"
		echo "# 由 luci-app-likepc 自动生成（流量拦截），请勿手工修改"
		echo "# 内网($lan) -> WAN($wan)"
		echo
		echo "# 先按 multiport 加；模块缺失时退回逐条 --dport（范围写成 a:b）"
		echo "_blk_ports() {"
		echo "	_p=\"\$1\"; _l=\"\$2\""
		echo "	iptables -A likepc_blk -p \"\$_p\" -m multiport --dports \"\$_l\" -j DROP 2>/dev/null && return 0"
		echo "	_o=\"\$IFS\"; IFS=','"
		echo "	for _one in \$_l; do"
		echo "		IFS=\"\$_o\""
		echo "		case \"\$_one\" in"
		echo "			*-*) iptables -A likepc_blk -p \"\$_p\" --dport \"\${_one%-*}:\${_one#*-}\" -j DROP 2>/dev/null ;;"
		echo "			*)   iptables -A likepc_blk -p \"\$_p\" --dport \"\$_one\" -j DROP 2>/dev/null ;;"
		echo "		esac"
		echo "	done"
		echo "	IFS=\"\$_o\""
		echo "}"

		if blk_any_forward; then
			echo
			echo "while iptables -D FORWARD -i $lan -o $wan -j likepc_blk 2>/dev/null; do :; done"
			echo "iptables -N likepc_blk 2>/dev/null"
			echo "iptables -F likepc_blk 2>/dev/null"
			if [ "$(blk_flag p2p)" = "1" ]; then
				echo "_blk_ports tcp \"$(echo "$BLK_P2P_TCP" | tr ' ' ',')\""
				echo "_blk_ports udp \"$(echo "$BLK_P2P_UDP" | tr ' ' ',')\""
			fi
			if [ "$(blk_flag remote)" = "1" ]; then
				echo "_blk_ports tcp \"$(echo "$BLK_REMOTE_TCP" | tr ' ' ',')\""
				echo "_blk_ports udp \"$(echo "$BLK_REMOTE_UDP" | tr ' ' ',')\""
			fi
			if [ "$(blk_flag stun)" = "1" ]; then
				echo "_blk_ports tcp \"$(echo "$BLK_STUN_TCP" | tr ' ' ',')\""
				echo "_blk_ports udp \"$(echo "$BLK_STUN_UDP" | tr ' ' ',')\""
			fi
			echo "iptables -I FORWARD 1 -i $lan -o $wan -j likepc_blk"
		fi

		if [ "$(blk_flag nat4)" = "1" ]; then
			echo
			echo "while iptables -t nat -D POSTROUTING -o $wan -j likepc_nat 2>/dev/null; do :; done"
			echo "iptables -t nat -N likepc_nat 2>/dev/null"
			echo "iptables -t nat -F likepc_nat 2>/dev/null"
			echo "if iptables -t nat -A likepc_nat -j MASQUERADE --random-fully 2>/dev/null; then"
			echo "	logger -t likepc \"NAT4: MASQUERADE --random-fully\""
			echo "elif iptables -t nat -A likepc_nat -j MASQUERADE --random 2>/dev/null; then"
			echo "	logger -t likepc \"NAT4: 内核不支持 --random-fully，已退回 --random\""
			echo "else"
			echo "	iptables -t nat -A likepc_nat -j MASQUERADE"
			echo "	logger -t likepc \"NAT4: iptables 太旧，只能用普通 MASQUERADE\""
			echo "fi"
			echo "iptables -t nat -I POSTROUTING 1 -o $wan -j likepc_nat"
		fi
	} >"$BLK_FW3"

	chmod 0755 "$BLK_FW3" 2>/dev/null
	return 0
}
blk_include_section() {
	local path="$1" sec

	for sec in $(uci -q show firewall 2>/dev/null | grep '=include$' | cut -d. -f2 | cut -d= -f1); do
		if [ "$(uci -q get "firewall.$sec.path" 2>/dev/null)" = "$path" ]; then
			echo "$sec"
			return 0
		fi
	done

	return 1
}

blk_include_add() {
	local path="$1" type="$2"

	blk_include_section "$path" >/dev/null && return 0

	uci -q add firewall include
	uci -q set firewall.@include[-1].type="$type"
	uci -q set firewall.@include[-1].path="$path"
	uci -q set firewall.@include[-1].enabled='1'
	uci -q commit firewall
	return 0
}

blk_include_del() {
	local path="$1" sec

	while sec=$(blk_include_section "$path"); do
		uci -q delete "firewall.$sec"
		uci -q commit firewall
	done

	return 0
}

blk_apply() {
	if ! blk_any; then
		blk_include_del "$BLK_NFT"
		blk_include_del "$BLK_FW3"
		rm -f "$BLK_NFT" "$BLK_FW3" 2>/dev/null
		/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1
		return 0
	fi

	if [ "$(fw_version)" = "4" ]; then
		blk_include_del "$BLK_FW3"
		rm -f "$BLK_FW3" 2>/dev/null
		blk_render_nft "$BLK_NFT.new"
		if ! blk_validate_nft "$BLK_NFT.new"; then
			rm -f "$BLK_NFT.new" 2>/dev/null
			log "nft 规则校验没通过，本次没有改动防火墙"
			return 1
		fi
		mv "$BLK_NFT.new" "$BLK_NFT" 2>/dev/null || return 1
		blk_include_add "$BLK_NFT" nftables
	else
		blk_include_del "$BLK_NFT"
		rm -f "$BLK_NFT" 2>/dev/null
		blk_render_fw3
		blk_include_add "$BLK_FW3" script
	fi

	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1
	return 0
}

# ------------------------------------------------------------------ 四组开关
# 打开开关 -> 生成规则 -> 失败自动回滚（避免界面显示已开启、实际没生效）
blk_commit() {
	local name="$1" msg="$2"

	blk_on "$name"
	if blk_apply; then
		log "$msg"
		return 0
	fi

	blk_off "$name"
	blk_apply
	log "规则生成失败，已回滚"
	return 1
}

blk_p2p() {
	blk_commit p2p "已阻断 P2P 下载（BT / eMule / 迅雷 默认端口，对所有内网设备生效）"
	return 0
}

blk_p2p_undo() {
	blk_off p2p
	blk_apply
	log "已恢复 P2P 下载"
	return 0
}

blk_remote() {
	blk_commit remote "已阻断远程控制（RustDesk / TeamViewer / AnyDesk / VNC，对所有内网设备生效）"
	return 0
}

blk_remote_undo() {
	blk_off remote
	blk_apply
	log "已恢复远程控制"
	return 0
}

blk_stun() {
	blk_commit stun "已阻断 STUN/TURN（NAT 类型探测与 WebRTC 打洞，对所有内网设备生效）"
	return 0
}

blk_stun_undo() {
	blk_off stun
	blk_apply
	log "已恢复 STUN/TURN"
	return 0
}

blk_nat4() {
	blk_commit nat4 "已强制对称 NAT（random-fully）：每个目标分配不同外部端口，主动打洞会失效"
	return 0
}

blk_nat4_undo() {
	blk_off nat4
	blk_apply
	log "已恢复正常 NAT 端口分配"
	return 0
}
# 卸载 / 清空用：四个开关全部关掉，并删掉 include 段与生成的文件
blk_clear() {
	blk_off p2p
	blk_off remote
	blk_off stun
	blk_off nat4
	blk_include_del "$BLK_NFT"
	blk_include_del "$BLK_FW3"
	rm -f "$BLK_NFT" "$BLK_FW3" "$BLK_NFT.new" 2>/dev/null
	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1
	log "已移除全部流量拦截规则"
	return 0
}