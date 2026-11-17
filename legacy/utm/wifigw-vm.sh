#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
# wifigw-vm.sh - make a UTM Linux VM the Wi-Fi gateway ("Wi-Fi B") for the Mac.
#
# Run INSIDE the VM (Debian 12+ / Ubuntu 22.04+, arm64) as root:
#   sudo bash wifigw-vm.sh [options]    set up (safe to run again)
#   sudo bash wifigw-vm.sh status       show the current state
#   sudo bash wifigw-vm.sh uninstall    undo what this script configured
#
# Options:
#   --ssid NAME       Wi-Fi B network name (default: pick from a scan)
#   --password PASS   Wi-Fi B password (default: asked, not echoed)
#   --open            Wi-Fi B has no password
#   --hidden          Wi-Fi B does not broadcast its name
#   --ip ADDR/PFX     static IPv4 on Wi-Fi B (networks without DHCP), e.g. 192.168.50.20/24
#   --gw IP           default gateway for --ip            --dns "IP,IP"  DNS servers
#   --route "NET GW"  extra route behind another router on Wi-Fi B (repeatable),
#                     e.g. --route "10.10.0.0/24 192.168.50.254"
#   --keep-wifi       don't join; use the Wi-Fi connection that is already up
#                     (e.g. an 802.1X network you set up yourself with nmcli)
#   --wireguard       also run a WireGuard server and write configs for the Mac
#   --wifi IFACE      Wi-Fi interface (default: auto-detect)
#   --lan IFACE       interface facing the Mac/UTM (default: auto-detect)
#   --usb3            let Realtek rtw88 dongles switch to USB 3 mode
#
# Steps: packages -> keep rtw88 dongles in USB 2 mode -> join Wi-Fi B -> take
# the default route and DNS away from the Mac-facing interface (the VM then uses
# ONLY Wi-Fi B) -> IPv4 forwarding + NAT + block inbound from Wi-Fi B -> WireGuard.
# Messages are English on purpose: the Linux text console in UTM has no Korean font.

set -euo pipefail
trap '' HUP   # keep going if an SSH session drops while networking is reconfigured

STATE_DIR=/etc/wifigw
STATE_FILE=$STATE_DIR/state
NFT_FILE=$STATE_DIR/firewall.nft
NAT_UNIT=wifigw-nat.service
RTW_CONF=/etc/modprobe.d/wifigw-rtw88.conf
NM_CONF=/etc/NetworkManager/conf.d/90-wifigw.conf
DHCLIENT_HOOK=/etc/dhcp/dhclient-enter-hooks.d/wifigw
WIFI_CON=wifigw-wifi
LAN_CON_NEW=wifigw-lan
WG_IF=wifigw0
WG_NET=10.77.0
WG_PORT=51820

SSID="" PASSWORD="" PASSWORD_SET=0 HIDDEN=0 KEEP_WIFI=0 WANT_WG=0 USB3=0 MODE=setup
WIFI_IF="" LAN_IF="" LAN_MODE="" LAN_CON="" LAN_DROPIN="" APT_UPDATED=0
STATIC_IP="" STATIC_GW="" STATIC_DNS="" STATIC_ROUTES=""

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# ------------------------------------------------------------------ helpers
# Value helpers print nothing (and still succeed) when there is no answer.
iface_exists() { [ -n "${1:-}" ] && [ -e "/sys/class/net/$1" ]; }
is_wireless()  { [ -d "/sys/class/net/$1/wireless" ] || [ -d "/sys/class/net/$1/phy80211" ]; }
is_wired_nic() { [ "$1" != lo ] && [ -e "/sys/class/net/$1/device" ] && ! is_wireless "$1"; }
ipv4_cidr()    { ip -4 -o addr show dev "$1" 2>/dev/null | awk 'NR == 1 { print $4 }' || true; }
subnet_of()    { ip -4 route show dev "$1" proto kernel scope link 2>/dev/null | awk 'NR == 1 { print $1 }' || true; }
wifi_nets()    { ip -4 route show dev "$1" 2>/dev/null | awk '$1 != "default" { print $1 }' | paste -sd ' ' - || true; }   # its subnet + extra routes
gateway_of()   { ip -4 route show default dev "$1" 2>/dev/null | awk 'NR == 1 { print $3 }' || true; }
nm_state()     { nmcli -g GENERAL.STATE device show "$1" 2>/dev/null || true; }
nm_con_of()    { nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null || true; }
nm_has_con()   { nmcli -g NAME connection show 2>/dev/null | grep -Fx -- "$1" >/dev/null; }
pkg_ok()       { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -F 'install ok installed' >/dev/null; }
state_get()    { if [ -f "$STATE_FILE" ]; then sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1; fi; }
need_val()     { [ $# -ge 2 ] || die "$1 needs a value"; }

save_state() {
  mkdir -p "$STATE_DIR"
  printf 'WIFI_IF=%s\nLAN_IF=%s\nLAN_MODE=%s\nLAN_CON=%s\nLAN_DROPIN=%s\n' \
    "$WIFI_IF" "$LAN_IF" "$LAN_MODE" "$LAN_CON" "$LAN_DROPIN" > "$STATE_FILE"
}

# ---------------------------------------------------------------- discovery
find_wifi_if() {
  local d
  for d in /sys/class/net/*; do
    if is_wireless "${d##*/}"; then echo "${d##*/}"; return 0; fi
  done
}

find_lan_if() {   # the wired NIC UTM gives us (virtio), i.e. the link to the Mac
  local prev dev d
  prev=$(state_get LAN_IF)
  if iface_exists "$prev"; then echo "$prev"; return 0; fi
  for dev in $(ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' || true); do
    if is_wired_nic "$dev"; then echo "$dev"; return 0; fi
  done
  for d in /sys/class/net/*; do
    if is_wired_nic "${d##*/}"; then echo "${d##*/}"; return 0; fi
  done
}

# ----------------------------------------------------------------- packages
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  if [ "$APT_UPDATED" -eq 0 ]; then apt-get update -qq; APT_UPDATED=1; fi
  apt-get install -y -qq --no-install-recommends "$@"   # no ModemManager/ppp/polkit: keep the VM small
}

install_packages() {
  # wpasupplicant is only a Recommends of network-manager, but Wi-Fi needs it
  local p pkgs=(network-manager wpasupplicant nftables openssh-server iw wireless-regdb usbutils curl) missing=()
  if [ "$WANT_WG" -eq 1 ]; then pkgs+=(wireguard-tools); fi
  for p in "${pkgs[@]}"; do pkg_ok "$p" || missing+=("$p"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installing: ${missing[*]}"
    apt_install "${missing[@]}" || die "apt-get failed - does the VM have internet? (UTM network: Shared Network)"
  fi
  systemctl enable --now NetworkManager >/dev/null 2>&1 || die "NetworkManager did not start"
  systemctl enable --now ssh >/dev/null 2>&1 || warn "the SSH server did not start"
}

configure_rtw88() {
  # The rtw88 driver switches USB 3 capable Realtek dongles from USB 2 to USB 3
  # mode on probe. The device then drops off the bus and re-enumerates, which
  # pulls it out of the UTM passthrough. Keep it in USB 2 mode unless --usb3.
  local param=/sys/module/rtw88_usb/parameters/switch_usb_mode
  if [ "$USB3" -eq 1 ]; then rm -f "$RTW_CONF"; return 0; fi
  modinfo -p rtw88_usb 2>/dev/null | grep '^switch_usb_mode:' >/dev/null || return 0
  mkdir -p "${RTW_CONF%/*}"
  echo 'options rtw88_usb switch_usb_mode=N' > "$RTW_CONF"
  if [ -w "$param" ]; then echo N > "$param" 2>/dev/null || true; fi
  log "Realtek rtw88: USB 3 mode switch disabled (dongle stays in USB 2 mode; --usb3 to allow)"
}

install_firmware() {
  local os
  os=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
  if [ "$os" = ubuntu ]; then
    pkg_ok linux-firmware || apt_install linux-firmware || warn "could not install linux-firmware"
  elif ! { pkg_ok firmware-realtek && pkg_ok firmware-misc-nonfree; }; then
    apt_install firmware-realtek firmware-misc-nonfree ||
      warn "firmware packages not found - add the 'non-free-firmware' component to your apt sources and run this again"
  fi
}

# ------------------------------------------------------------------ Wi-Fi B
reprobe_usb() {   # ask the kernel to bind drivers to USB interfaces that have none (e.g. after firmware install)
  local d
  for d in /sys/bus/usb/devices/*:*; do
    [ -e "$d" ] && [ ! -e "$d/driver" ] || continue
    echo "${d##*/}" > /sys/bus/usb/drivers_probe 2>/dev/null || true
  done
}

prompt_attach() {
  [ -t 0 ] || return 0
  echo
  echo "  No Wi-Fi interface in the VM yet."
  echo "  In UTM: toolbar USB icon -> select the dongle (e.g. 'Realtek 802.11ac NIC')."
  echo "  If it was attached and dropped out, select it again."
  read -r -p "  Press Enter when done (Ctrl+C to abort)... " _ || true
  sleep 4
}

wait_for_wifi() {
  if [ -n "$WIFI_IF" ]; then
    iface_exists "$WIFI_IF" || die "no such interface: $WIFI_IF"
    return 0
  fi
  local step
  for step in probe ask firmware ask fail; do
    WIFI_IF=$(find_wifi_if)
    [ -n "$WIFI_IF" ] && break
    case $step in
      probe)    reprobe_usb; sleep 2 ;;
      ask)      prompt_attach ;;
      firmware) log "Installing Wi-Fi firmware"; install_firmware; reprobe_usb; sleep 4 ;;
      fail)
        echo "--- lsusb ---"; lsusb 2>/dev/null || true
        echo "--- kernel log ---"; dmesg 2>/dev/null | grep -Ei 'usb|rtw|mt7|firmware|wlan' | tail -n 20 || true
        die "no Wi-Fi interface - see the README (troubleshooting)" ;;
    esac
  done
  log "Wi-Fi interface: $WIFI_IF"
}

join_wifi() {
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli device set "$WIFI_IF" managed yes >/dev/null 2>&1 || true
  if [ -z "$SSID" ]; then
    [ -t 0 ] || die "--ssid is required when not running interactively"
    log "Scanning on $WIFI_IF..."
    nmcli device wifi rescan ifname "$WIFI_IF" >/dev/null 2>&1 || true
    local list="" n
    for n in 1 2 3 4 5 6 7 8; do   # a freshly started NetworkManager needs a few seconds for its first scan
      sleep 2
      list=$(nmcli -f IN-USE,SSID,CHAN,SIGNAL,SECURITY device wifi list ifname "$WIFI_IF" 2>/dev/null || true)
      [ "$(printf '%s\n' "$list" | wc -l)" -gt 1 ] && break
    done
    printf '%s\n' "$list"
    read -r -p "SSID for Wi-Fi B: " SSID
    [ -n "$SSID" ] || die "no SSID given"
  fi
  if [ "$PASSWORD_SET" -eq 0 ]; then
    [ -t 0 ] || die "--password or --open is required when not running interactively"
    read -r -s -p "Password for '$SSID' (empty = open network): " PASSWORD
    echo
  fi
  log "Joining '$SSID' with $WIFI_IF${STATIC_IP:+ (static $STATIC_IP)}..."
  nmcli connection delete "$WIFI_CON" >/dev/null 2>&1 || true
  local args=() cidr="" i sec km=wpa-psk ok=1
  if [ -n "$STATIC_IP" ]; then
    # build the profile ourselves so NetworkManager never waits for DHCP on a network that has none
    sec=$(nmcli -t -f SSID,SECURITY device wifi list --rescan auto ifname "$WIFI_IF" 2>/dev/null |
          awk -F: -v s="$SSID" '$1 == s && !d { print $2; d = 1 }' || true)
    case "$sec" in *WPA3*) case "$sec" in *WPA1*|*WPA2*) ;; *) km=sae ;; esac ;; esac
    args=(connection add type wifi ifname "$WIFI_IF" con-name "$WIFI_CON" ssid "$SSID"
          connection.autoconnect yes 802-11-wireless.powersave 2
          ipv4.method manual ipv4.addresses "$STATIC_IP")
    if [ -n "$STATIC_GW" ]; then args+=(ipv4.gateway "$STATIC_GW"); fi
    if [ -n "$STATIC_DNS" ]; then args+=(ipv4.dns "$STATIC_DNS"); fi
    if [ -n "$STATIC_ROUTES" ]; then args+=(ipv4.routes "$STATIC_ROUTES"); fi
    if [ "$HIDDEN" -eq 1 ]; then args+=(802-11-wireless.hidden yes); fi
    if [ -n "$PASSWORD" ]; then args+=(wifi-sec.key-mgmt "$km" wifi-sec.psk "$PASSWORD"); fi
    { nmcli "${args[@]}" >/dev/null && nmcli -w 60 connection up "$WIFI_CON" >/dev/null; } || ok=0
  else
    args=(device wifi connect "$SSID" ifname "$WIFI_IF" name "$WIFI_CON")
    if [ -n "$PASSWORD" ]; then args+=(password "$PASSWORD"); fi
    if [ "$HIDDEN" -eq 1 ]; then args+=(hidden yes); fi
    nmcli -w 60 "${args[@]}" >/dev/null || ok=0
  fi
  if [ "$ok" -eq 0 ]; then
    nmcli connection delete "$WIFI_CON" >/dev/null 2>&1 || true   # stop NetworkManager from retrying forever
    die "could not join '$SSID' - see nmcli's message above. 'Secrets were required': wrong password. 'IP configuration could not be reserved': joined, but the network gave no IP address - if it has no DHCP, pass --ip/--gw (and --route); some office networks only serve registered devices (this dongle's MAC: $(cat "/sys/class/net/$WIFI_IF/address" 2>/dev/null))."
  fi
  nmcli connection modify "$WIFI_CON" connection.autoconnect yes 802-11-wireless.powersave 2 >/dev/null 2>&1 || true
  iw dev "$WIFI_IF" set power_save off 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    cidr=$(ipv4_cidr "$WIFI_IF")
    [ -n "$cidr" ] && break
    sleep 1
  done
  [ -n "$cidr" ] || die "joined '$SSID' but got no IPv4 address (DHCP?)"
  log "Wi-Fi B: '$SSID'  $WIFI_IF = $cidr"
}

# ---------------------------------------------------- the Mac-facing link
# Goal: the link to the Mac keeps its address (so the Mac can reach the VM) but
# provides no default route and no DNS. Then everything the VM sends to the
# internet - including NATed traffic from the Mac - leaves through Wi-Fi B.

nm_owns() {   # NetworkManager manages the device (not just observing it)
  local s
  s=$(nm_state "$1")
  case "$s" in ""|*externally*) return 1 ;; esac
  [ "${s%% *}" -ge 20 ] 2>/dev/null
}

networkd_file() {   # the .network file systemd-networkd uses for $1 (netplan generates one)
  if command -v networkctl >/dev/null 2>&1; then
    networkctl status "$1" 2>/dev/null | awk -F': ' '/Network File:/ && $2 != "n/a" { print $2 }' | awk 'NR == 1' || true
  fi
}

keep_nm_off_lan() {
  # When systemd-networkd runs the Mac-facing link (Ubuntu Server, Debian cloud images), limit
  # NetworkManager to Wi-Fi - otherwise it starts a second DHCP client on that link.
  iface_exists "$LAN_IF" || return 0
  [ -n "$(networkd_file "$LAN_IF")" ] || return 0
  if nm_owns "$LAN_IF"; then return 0; fi
  mkdir -p "${NM_CONF%/*}"
  printf '# wifigw: NetworkManager handles only Wi-Fi; systemd-networkd keeps the UTM link\n[keyfile]\nunmanaged-devices=*,except:type:wifi\n' > "$NM_CONF"
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    nmcli general reload conf >/dev/null 2>&1 || systemctl reload NetworkManager >/dev/null 2>&1 || true
  fi
}

ifupdown_manages() {
  grep -sqE "^[[:space:]]*(auto|allow-[a-z-]+|iface)[[:space:]]+([^#]*[[:space:]])?$1([[:space:]]|\$)" \
    /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null
}

nm_take_lan() {   # hand the link to NetworkManager with a profile that never becomes the default route
  nmcli device set "$LAN_IF" managed yes >/dev/null 2>&1 || true
  if nm_has_con "$LAN_CON_NEW"; then nmcli connection delete "$LAN_CON_NEW" >/dev/null 2>&1 || true; fi
  nmcli connection add type ethernet ifname "$LAN_IF" con-name "$LAN_CON_NEW" \
    connection.autoconnect yes connection.autoconnect-priority 100 \
    ipv4.method auto ipv4.never-default yes ipv4.ignore-auto-dns yes \
    ipv6.method disabled >/dev/null
  nmcli -w 30 connection up "$LAN_CON_NEW" >/dev/null || warn "could not activate $LAN_CON_NEW"
  LAN_CON=$LAN_CON_NEW
}

isolate_lan_nm() {
  nmcli connection modify "$LAN_CON" ipv4.never-default yes ipv4.ignore-auto-dns yes \
    ipv6.never-default yes ipv6.ignore-auto-dns yes
  nmcli device reapply "$LAN_IF" >/dev/null 2>&1 || nmcli -w 30 connection up "$LAN_CON" >/dev/null || true
}

isolate_lan_networkd() {
  local dir="/etc/systemd/network/${1##*/}.d"
  mkdir -p "$dir"
  LAN_DROPIN="$dir/wifigw.conf"
  cat > "$LAN_DROPIN" <<'EOF'
# wifigw: the UTM host link only carries VM <-> Mac traffic (no default route, no DNS)
[Network]
IPv6AcceptRA=no

[DHCPv4]
UseGateway=no
UseRoutes=no
UseDNS=no
EOF
  networkctl reload >/dev/null 2>&1 || systemctl restart systemd-networkd
  networkctl reconfigure "$LAN_IF" >/dev/null 2>&1 || true
}

isolate_lan_ifupdown() {   # keep ifupdown, but tell its DHCP client to skip the gateway and DNS
  mkdir -p "${DHCLIENT_HOOK%/*}"
  cat > "$DHCLIENT_HOOK" <<EOF
# wifigw: the UTM host link ($LAN_IF) only carries VM <-> Mac traffic
if [ "\$interface" = "$LAN_IF" ]; then
  unset new_routers
  make_resolv_conf() { :; }
fi
EOF
  if command -v dhcpcd >/dev/null 2>&1; then
    touch /etc/dhcpcd.conf
    sed -i '/^# wifigw-begin$/,/^# wifigw-end$/d' /etc/dhcpcd.conf
    printf '# wifigw-begin\ninterface %s\nnogateway\nnohook resolv.conf\n# wifigw-end\n' "$LAN_IF" >> /etc/dhcpcd.conf
    if pgrep -x dhcpcd >/dev/null; then dhcpcd -n "$LAN_IF" >/dev/null 2>&1 || true; fi
  fi
}

isolate_lan() {
  iface_exists "$LAN_IF" || die "could not find the Mac-facing interface (use --lan IFACE)"
  [ "$LAN_IF" != "$WIFI_IF" ] || die "the Mac-facing and the Wi-Fi interface are the same ($LAN_IF)"
  log "Mac-facing interface: $LAN_IF $(ipv4_cidr "$LAN_IF") - removing its default route and DNS"
  local con nf
  if nm_owns "$LAN_IF"; then
    con=$(nm_con_of "$LAN_IF")
    if [ "$con" = "$LAN_CON_NEW" ]; then
      LAN_MODE=${LAN_MODE:-nmnew} LAN_CON=$con   # our own profile from an earlier run
    elif [ -n "$con" ] && [ "$con" != "--" ]; then
      LAN_MODE=nm LAN_CON=$con
      isolate_lan_nm
    else
      LAN_MODE=nmnew
      nm_take_lan
    fi
  elif nf=$(networkd_file "$LAN_IF"); [ -n "$nf" ]; then
    LAN_MODE=networkd
    isolate_lan_networkd "$nf"
  elif ifupdown_manages "$LAN_IF"; then
    LAN_MODE=ifupdown
    isolate_lan_ifupdown
  else
    warn "unknown network manager for $LAN_IF - handing it to NetworkManager"
    LAN_MODE=nmnew
    nm_take_lan
  fi
  save_state
  sleep 3
  # remove a default route that is already installed (the managers won't add it back)
  while ip -4 route show default dev "$LAN_IF" 2>/dev/null | grep . >/dev/null; do
    ip -4 route del default dev "$LAN_IF" 2>/dev/null || break
  done
  ip -6 route del default dev "$LAN_IF" 2>/dev/null || true
}

# ------------------------------------------------------- forwarding + NAT
enable_nat() {
  local wl="wl*" nft rules
  case "$WIFI_IF" in wl*) ;; *) wl=$WIFI_IF ;; esac
  nft=$(command -v nft) || die "nft not found"
  mkdir -p "$STATE_DIR" /etc/sysctl.d /etc/systemd/system
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wifigw.conf
  sysctl -q -w net.ipv4.ip_forward=1
  cat > "$NFT_FILE" <<EOF
# wifigw: NAT out through Wi-Fi B; no new inbound connections from Wi-Fi B
table inet wifigw
delete table inet wifigw
table inet wifigw {
	chain input {
		type filter hook input priority 0; policy accept;
		iifname "$wl" ct state established,related accept
		iifname "$wl" meta l4proto ipv6-icmp accept
		iifname "$wl" udp dport { 68, 546 } accept
		iifname "$wl" drop
	}
	chain forward {
		type filter hook forward priority 0; policy accept;
		iifname "$wl" ct state established,related accept
		iifname "$wl" drop
	}
	chain postrouting {
		type nat hook postrouting priority 100; policy accept;
		oifname "$wl" meta nfproto ipv4 masquerade
	}
}
EOF
  cat > "/etc/systemd/system/$NAT_UNIT" <<EOF
[Unit]
Description=wifigw: NAT and firewall for Wi-Fi B
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nft -f $NFT_FILE
ExecStop=-$nft delete table inet wifigw

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$NAT_UNIT" >/dev/null 2>&1
  systemctl restart "$NAT_UNIT" || die "loading $NFT_FILE failed (journalctl -u $NAT_UNIT)"
  log "IPv4 forwarding + NAT out of $wl on; new inbound connections from Wi-Fi B are blocked"
  rules=$(nft list ruleset 2>/dev/null || true)
  if printf '%s\n' "$rules" | grep 'hook forward' | grep 'policy drop' >/dev/null; then
    warn "another firewall drops forwarded packets (ufw? docker?) - allow $LAN_IF -> $WIFI_IF there too"
  fi
}

# ---------------------------------------------------------------- WireGuard
write_wg_client() {   # file allowed-ips [dns] - uses cpriv, spub, lan_ip from setup_wireguard
  {
    echo "[Interface]"
    echo "PrivateKey = $cpriv"
    echo "Address = $WG_NET.2/32"
    if [ -n "${3:-}" ]; then echo "DNS = $3"; fi
    echo
    echo "[Peer]"
    echo "PublicKey = $spub"
    echo "Endpoint = $lan_ip:$WG_PORT"
    echo "AllowedIPs = $2"
  } > "$1"
}

setup_wireguard() {
  local owner home out lan_ip nets dns spriv spub cpriv cpub old_umask
  owner=${SUDO_USER:-root}
  home=$(getent passwd "$owner" | cut -d: -f6)
  out="${home:-/root}/wifigw"
  lan_ip=$(ipv4_cidr "$LAN_IF"); lan_ip=${lan_ip%/*}
  nets=$(wifi_nets "$WIFI_IF")                 # Wi-Fi B's subnet plus its extra routes
  dns=$(nmcli -g IP4.DNS device show "$WIFI_IF" 2>/dev/null | sed 's/ | /, /g' || true)   # empty: keep the Mac's DNS
  [ -n "$lan_ip" ] && [ -n "$nets" ] || die "WireGuard: no IPv4 on $LAN_IF or no network on $WIFI_IF"

  old_umask=$(umask)
  umask 077
  mkdir -p /etc/wireguard "$out"
  [ -s /etc/wireguard/wifigw-server.key ] || wg genkey > /etc/wireguard/wifigw-server.key
  [ -s /etc/wireguard/wifigw-mac.key ] || wg genkey > /etc/wireguard/wifigw-mac.key
  spriv=$(cat /etc/wireguard/wifigw-server.key); spub=$(wg pubkey < /etc/wireguard/wifigw-server.key)
  cpriv=$(cat /etc/wireguard/wifigw-mac.key);    cpub=$(wg pubkey < /etc/wireguard/wifigw-mac.key)
  cat > "/etc/wireguard/$WG_IF.conf" <<EOF
[Interface]
Address = $WG_NET.1/24
ListenPort = $WG_PORT
PrivateKey = $spriv

[Peer]
# the Mac
PublicKey = $cpub
AllowedIPs = $WG_NET.2/32
EOF
  write_wg_client "$out/wifiB-lan.conf" "$(echo "$nets" | sed 's/ /, /g')"
  write_wg_client "$out/wifiB-all.conf" "0.0.0.0/0" "$dns"
  umask "$old_umask"
  chown -R "$owner": "$out"

  systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1
  systemctl restart "wg-quick@$WG_IF" || die "WireGuard did not start (journalctl -u wg-quick@$WG_IF)"
  log "WireGuard: listening on $lan_ip:$WG_PORT, Mac configs in $out"
}

# --------------------------------------------------------- status / uninstall
show_status() {
  local wifi lan pub dns
  wifi=${WIFI_IF:-$(state_get WIFI_IF)}; iface_exists "$wifi" || wifi=$(find_wifi_if)
  lan=${LAN_IF:-$(state_get LAN_IF)};   iface_exists "$lan" || lan=$(find_lan_if)
  if command -v resolvectl >/dev/null 2>&1 && resolvectl dns >/dev/null 2>&1; then
    dns=$(resolvectl dns 2>/dev/null | paste -sd ';' - || true)
  else
    dns=$(awk '/^nameserver/ { printf "%s ", $2 }' /etc/resolv.conf 2>/dev/null || true)
  fi
  echo
  echo "  Wi-Fi B        : ${wifi:-not found}  $(ipv4_cidr "$wifi")  [$(nm_con_of "$wifi")]"
  echo "  Via Wi-Fi B    : $(wifi_nets "$wifi")  (gateway $(gateway_of "$wifi"))"
  echo "  Mac-facing NIC : ${lan:-not found}  $(ipv4_cidr "$lan")  (mode: $(state_get LAN_MODE))"
  echo "  Default routes : $(ip -4 route show default 2>/dev/null | paste -sd ';' - || true)"
  echo "  DNS            : $dns"
  echo "  IP forwarding  : $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true)"
  echo "  NAT / firewall : $(systemctl is-active "$NAT_UNIT" 2>/dev/null || true)"
  echo "  WireGuard      : $(systemctl is-active "wg-quick@$WG_IF" 2>/dev/null || true)"
  if iface_exists "$wifi"; then
    pub=$(curl -s --max-time 6 --interface "$wifi" https://api.ipify.org 2>/dev/null || true)
    echo "  Public IP (B)  : ${pub:-unreachable - captive portal, or no internet on Wi-Fi B?}"
  fi
  echo
}

print_mac_hints() {
  local ip net
  ip=$(ipv4_cidr "$LAN_IF"); ip=${ip%/*}
  echo "Next, on the Mac (in the folder with wifigw-mac.sh):"
  echo "  ./wifigw-mac.sh setup ${ip:-<VM IP>} ${SUDO_USER:-<user>}"
  for net in $(wifi_nets "$WIFI_IF"); do
    echo "  ./wifigw-mac.sh route add $net   # through the VM to Wi-Fi B"
  done
  echo "  ./wifigw-mac.sh proxy                    # SOCKS5 127.0.0.1:1080 through Wi-Fi B"
  if [ -f "/etc/wireguard/$WG_IF.conf" ]; then
    echo "  ./wifigw-mac.sh wg-fetch                 # WireGuard configs for the Mac app"
  fi
}

do_uninstall() {
  local lan
  lan=$(state_get LAN_IF)
  log "Removing the wifigw configuration"
  systemctl disable --now "wg-quick@$WG_IF" >/dev/null 2>&1 || true
  rm -f "/etc/wireguard/$WG_IF.conf" /etc/wireguard/wifigw-server.key /etc/wireguard/wifigw-mac.key
  systemctl disable --now "$NAT_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$NAT_UNIT" /etc/sysctl.d/99-wifigw.conf "$RTW_CONF" "$NM_CONF"
  systemctl daemon-reload
  nmcli general reload conf >/dev/null 2>&1 || true
  sysctl -q -w net.ipv4.ip_forward=0 || true
  nmcli connection delete "$WIFI_CON" >/dev/null 2>&1 || true
  case "$LAN_MODE" in
    nm|nmnew)
      if [ -n "$LAN_CON" ]; then
        nmcli connection modify "$LAN_CON" ipv4.never-default no ipv4.ignore-auto-dns no \
          ipv6.never-default no ipv6.ignore-auto-dns no >/dev/null 2>&1 || true
        nmcli -w 30 connection up "$LAN_CON" >/dev/null 2>&1 || true
      fi ;;
    networkd)
      rm -f "$LAN_DROPIN"
      rmdir "${LAN_DROPIN%/*}" 2>/dev/null || true
      networkctl reload >/dev/null 2>&1 || true
      networkctl reconfigure "$lan" >/dev/null 2>&1 || true ;;
    ifupdown)
      rm -f "$DHCLIENT_HOOK"
      if [ -f /etc/dhcpcd.conf ]; then sed -i '/^# wifigw-begin$/,/^# wifigw-end$/d' /etc/dhcpcd.conf; fi
      warn "reboot (or: ifdown $lan; ifup $lan) to get the default route back on $lan" ;;
  esac
  rm -rf "$STATE_DIR"
  log "Done. Installed packages were kept; ~/wifigw (Mac configs) can be deleted."
}

# --------------------------------------------------------------------- main
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      setup|status|uninstall) MODE=$1 ;;
      --ssid)      need_val "$@"; SSID=$2; shift ;;
      --password)  need_val "$@"; PASSWORD=$2; PASSWORD_SET=1; shift ;;
      --open)      PASSWORD=""; PASSWORD_SET=1 ;;
      --hidden)    HIDDEN=1 ;;
      --ip)        need_val "$@"; STATIC_IP=$2; case "$2" in */*) ;; *) STATIC_IP="$2/24" ;; esac; shift ;;
      --gw)        need_val "$@"; STATIC_GW=$2; shift ;;
      --dns)       need_val "$@"; STATIC_DNS=$2; shift ;;
      --route)     need_val "$@"; STATIC_ROUTES="${STATIC_ROUTES:+$STATIC_ROUTES, }$2"; shift ;;
      --keep-wifi) KEEP_WIFI=1 ;;
      --wireguard) WANT_WG=1 ;;
      --wifi)      need_val "$@"; WIFI_IF=$2; shift ;;
      --lan)       need_val "$@"; LAN_IF=$2; shift ;;
      --usb3)      USB3=1 ;;
      -h|--help)   usage; return 0 ;;
      *)           die "unknown argument: $1 (try --help)" ;;
    esac
    shift
  done

  LAN_MODE=$(state_get LAN_MODE) LAN_CON=$(state_get LAN_CON) LAN_DROPIN=$(state_get LAN_DROPIN)
  if [ "$MODE" = status ]; then show_status; return 0; fi
  [ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash $0 $MODE ..."
  command -v apt-get >/dev/null 2>&1 || die "only Debian/Ubuntu (apt) is supported"
  if [ "$MODE" = uninstall ]; then do_uninstall; return 0; fi

  log "wifigw setup"
  LAN_IF=${LAN_IF:-$(find_lan_if)}   # before Wi-Fi B brings its own default route
  keep_nm_off_lan                    # before NetworkManager gets installed
  install_packages
  configure_rtw88
  wait_for_wifi
  if [ "$KEEP_WIFI" -eq 1 ]; then
    [ -n "$(ipv4_cidr "$WIFI_IF")" ] || die "--keep-wifi: $WIFI_IF has no IPv4 address - connect it first (nmcli)"
    log "Using the existing connection on $WIFI_IF ($(ipv4_cidr "$WIFI_IF"))"
  else
    join_wifi
  fi
  isolate_lan
  enable_nat
  if [ "$WANT_WG" -eq 1 ]; then setup_wireguard; fi
  save_state
  show_status
  print_mac_hints
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
