#!/bin/bash
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: MIT
# wifigw-mac.sh - UTM VM의 USB Wi-Fi("Wi-Fi B")를 맥에서 쓰기 위한 도우미
#
# 사용법:
#   ./wifigw-mac.sh setup [VM_IP] [계정]         VM 주소와 로그인 계정 저장 (IP를 빼면 목록에서 고름)
#   ./wifigw-mac.sh vms                          UTM VM들이 받은 IP 목록
#   ./wifigw-mac.sh vm [옵션...]                 wifigw-vm.sh 를 VM에 복사하고 실행
#                                                (예: vm --wireguard / vm status / vm uninstall)
#   ./wifigw-mac.sh push                         wifigw-vm.sh 를 VM 홈 폴더로 복사만
#   ./wifigw-mac.sh route add <대역> [--force]   그 대역만 Wi-Fi B로 보냄 (sudo 필요)
#   ./wifigw-mac.sh route del <대역>             위에서 넣은 경로 삭제
#   ./wifigw-mac.sh route list                   VM을 거치는 경로 보기
#   ./wifigw-mac.sh proxy [포트]                 SOCKS5 프록시 127.0.0.1:포트 (기본 1080), Ctrl+C로 종료
#   ./wifigw-mac.sh browser [포트] [URL]         프록시를 쓰는 Wi-Fi B 전용 Chrome 창 열기
#   ./wifigw-mac.sh wg-fetch [폴더]              VM이 만든 WireGuard 설정 가져오기
#   ./wifigw-mac.sh status                       상태 확인 (맥 기본 경로 / Wi-Fi B 공인 IP 비교)
#   ./wifigw-mac.sh autostart install [VM이름] [VID:PID]
#                                                로그인하면 UTM VM을 켜고, 동글이 빠지면 다시 VM에 붙임
#                                                (기본: wifigw, 0BDA:B812)
#   ./wifigw-mac.sh autostart uninstall|status   자동 시작 제거 / 상태 보기
#
# 설정은 ~/.config/wifigw/config 에 저장돼요 (환경변수 WIFIGW_VM, WIFIGW_USER 가 우선).
# macOS 기본 bash 3.2에서 돌아가도록 작성했어요.

set -eu

CONF_DIR="$HOME/.config/wifigw"
CONF="$CONF_DIR/config"
LEASES=${WIFIGW_LEASES:-/var/db/dhcpd_leases}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IP_ECHO=https://api.ipify.org
UTMCTL=${WIFIGW_UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
AUTOSTART_LABEL=local.wifigw.autostart
# VM 호스트 키는 따로 보관해요: 192.168.64.x 를 다른 VM이 재사용해도 ~/.ssh/known_hosts 와 충돌하지 않게
SSH_BASE="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=~/.config/wifigw/known_hosts -o ConnectTimeout=8"
# 같은 VM으로 가는 ssh/scp 연결을 60초 동안 재사용해서 비밀번호를 한 번만 묻게 함
SSH_MUX="$SSH_BASE -o ControlMaster=auto -o ControlPath=~/.config/wifigw/cm-%C -o ControlPersist=60"

say()   { printf '%s\n' "$*"; }
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m주의:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m오류:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

conf_get() { if [ -f "$CONF" ]; then sed -n "s/^$1=//p" "$CONF" | tail -n 1; fi; }
VM_IP=${WIFIGW_VM:-$(conf_get VM_IP)}
VM_USER=${WIFIGW_USER:-$(conf_get VM_USER)}

# ------------------------------------------------------------- IPv4 계산
valid_ip() {
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' i
  [[ ${1:-} =~ $re ]] || return 1
  for i in 1 2 3 4; do [ $((10#${BASH_REMATCH[$i]})) -le 255 ] || return 1; done
}
ip2int() { local IFS=.; set -- $1; echo $(( (10#$1 << 24) + (10#$2 << 16) + (10#$3 << 8) + 10#$4 )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
prefix_mask() { if [ "$1" -eq 0 ]; then echo 0; else echo $(( (0xFFFFFFFF << (32 - $1)) & 0xFFFFFFFF )); fi; }
hexmask_prefix() {   # 0xffffff00 -> 24
  local m n=0
  m=$(( 16#${1#0x} ))
  while [ "$m" -gt 0 ]; do n=$(( n + (m & 1) )); m=$(( m >> 1 )); done
  echo "$n"
}
normalize_cidr() {   # 192.168.50.7/24 -> 192.168.50.0/24,  10.0.0.5 -> 10.0.0.5/32
  local ip len
  case $1 in */*) ip=${1%/*}; len=${1#*/} ;; *) ip=$1; len=32 ;; esac
  valid_ip "$ip" || return 1
  case $len in ''|*[!0-9]*) return 1 ;; esac
  [ "$len" -le 32 ] || return 1
  echo "$(int2ip $(( $(ip2int "$ip") & $(prefix_mask "$len") )))/$len"
}
cidr_overlap() {   # a/len b/len -> 겹치면 0
  local l=${1#*/} m
  if [ "${2#*/}" -lt "$l" ]; then l=${2#*/}; fi
  m=$(prefix_mask "$l")
  [ $(( $(ip2int "${1%/*}") & m )) -eq $(( $(ip2int "${2%/*}") & m )) ]
}

# -------------------------------------------------------- 맥 쪽 네트워크
mac_subnets() {   # "인터페이스 ip/prefix" - 맥이 직접 붙어 있는 IPv4 대역들
  local ifc ip mask
  ifconfig | awk '/^[^ \t]/ { ifc = $1; sub(/:$/, "", ifc) } $1 == "inet" && $3 == "netmask" { print ifc, $2, $4 }' |
    while read -r ifc ip mask; do
      case $ifc in lo*|utun*|awdl*|llw*|gif*|stf*|anpi*) continue ;; esac
      case $mask in 0x*) echo "$ifc $ip/$(hexmask_prefix "$mask")" ;; esac
    done
}

overlaps_mac() {   # 대역이 맥이 지금 붙어 있는 네트워크와 겹치면 0
  local hit=1 ifc net
  while read -r ifc net; do
    [ -n "${net:-}" ] || continue
    if cidr_overlap "$1" "$net"; then warn "$1 이(가) 맥 $ifc 의 대역 $net 과 겹쳐요."; hit=0; fi
  done <<EOF
$(mac_subnets)
EOF
  return $hit
}

need_vm()   { [ -n "$VM_IP" ] || die "VM 주소가 없어요. 먼저 ./wifigw-mac.sh setup 을 실행하세요."; }
need_user() { need_vm; [ -n "$VM_USER" ] || die "VM 계정이 없어요. ./wifigw-mac.sh setup $VM_IP <계정>"; }
vm_alive()  { ping -c 1 -t 2 "$VM_IP" >/dev/null 2>&1; }
port_open() { nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1; }

list_vms() {
  if [ ! -r "$LEASES" ]; then
    say "  (아직 기록이 없어요: $LEASES — Shared Network로 켠 VM이 있어야 해요)"
    return 0
  fi
  awk '
    /^\{/                { name = ""; ip = ""; hw = "" }
    /^[ \t]*name=/       { sub(/^[ \t]*name=/, "");              name = $0 }
    /^[ \t]*ip_address=/ { sub(/^[ \t]*ip_address=/, "");        ip = $0 }
    /^[ \t]*hw_address=/ { sub(/^[ \t]*hw_address=/, ""); if (sub(/^1,/, "")) hw = $0; else hw = "(DUID)" }
    /^\}/                { if (ip != "") printf "  %-16s %-18s %s\n", ip, hw, name }
  ' "$LEASES"
}

# ------------------------------------------------------------------ 명령
cmd_setup() {
  local ip=${1:-} user=${2:-}
  if [ -z "$ip" ]; then
    say "UTM VM 목록 (IP / MAC / 이름). 이름 열(VM의 호스트 이름)로 찾으면 쉬워요:"
    list_vms
    printf 'VM IP: '
    read -r ip || true
  fi
  valid_ip "$ip" || die "IP 형식이 아니에요: ${ip:-(빈 값)}"
  if [ -z "$user" ]; then
    printf 'VM 로그인 계정%s: ' "${VM_USER:+ [$VM_USER]}"
    read -r user || true
    user=${user:-$VM_USER}
  fi
  [ -n "$user" ] || die "계정 이름이 필요해요."
  mkdir -p "$CONF_DIR"
  printf 'VM_IP=%s\nVM_USER=%s\n' "$ip" "$user" > "$CONF"
  VM_IP=$ip VM_USER=$user
  info "저장했어요: $user@$ip ($CONF)"
  if ! vm_alive; then
    warn "VM이 ping에 응답하지 않아요. VM이 켜져 있는지 확인하세요."
  elif ssh $SSH_BASE -o BatchMode=yes "$user@$ip" true 2>/dev/null; then
    info "VM에 SSH 키로 접속돼요."
  else
    say "  팁: 비밀번호를 매번 치기 싫으면  ssh-copy-id $user@$ip"
  fi
}

cmd_push() {
  need_user
  [ -f "$SCRIPT_DIR/wifigw-vm.sh" ] || die "$SCRIPT_DIR 에 wifigw-vm.sh 가 없어요."
  mkdir -p "$CONF_DIR"
  # scp 대신 ssh 로 보냄: VM에 sftp 서버가 없거나 scp 가 막혀도 동작
  ssh $SSH_MUX "$VM_USER@$VM_IP" 'cat > wifigw-vm.sh' < "$SCRIPT_DIR/wifigw-vm.sh" ||
    die "복사하지 못했어요. VM이 켜져 있고 'ssh $VM_USER@$VM_IP' 로 접속되나요?"
  info "wifigw-vm.sh → $VM_USER@$VM_IP:~/wifigw-vm.sh"
}

cmd_vm() {
  local remote="sudo bash wifigw-vm.sh" a
  cmd_push
  for a in "$@"; do remote="$remote $(printf '%q' "$a")"; done
  info "VM에서 실행: $remote"
  exec ssh -t $SSH_MUX "$VM_USER@$VM_IP" "$remote"
}

route_list() {
  need_vm
  local r
  r=$(netstat -rn -f inet | awk -v gw="$VM_IP" '$2 == gw { print "  " $1 "  ->  " gw }')
  if [ -n "$r" ]; then say "$r"; else say "  (VM을 거치는 경로 없음)"; fi
}

cmd_route() {
  local sub=${1:-list} cidr kind target
  if [ $# -gt 0 ]; then shift; fi
  if [ "$sub" = add ] || [ "$sub" = del ] || [ "$sub" = delete ] || [ "$sub" = rm ]; then
    [ $# -ge 1 ] || die "대역을 적어 주세요. 예: ./wifigw-mac.sh route $sub 192.168.50.0/24"
    cidr=$(normalize_cidr "$1") || die "대역 형식이 아니에요: $1 (예: 192.168.50.0/24)"
    if [ "${cidr#*/}" = 32 ]; then kind=-host target=${cidr%/*}; else kind=-net target=$cidr; fi
  fi
  case $sub in
    add)
      need_vm
      vm_alive || die "VM($VM_IP)이 응답하지 않아요. VM이 켜져 있는지 확인하세요."
      if overlaps_mac "$cidr" && [ "${2:-}" != "--force" ]; then
        die "지금 쓰는 네트워크와 겹치는 대역을 VM으로 돌리면 그 네트워크가 끊길 수 있어요. 프록시나 WireGuard를 쓰거나, 그래도 하려면 끝에 --force"
      fi
      info "$cidr -> $VM_IP (Wi-Fi B)  [sudo 비밀번호를 물을 수 있어요]"
      sudo route -n add "$kind" "$target" "$VM_IP" >/dev/null ||
        die "경로를 넣지 못했어요. 이미 있으면 먼저: ./wifigw-mac.sh route del $cidr"
      info "추가했어요. VM을 끄거나 맥을 재부팅하면 사라져요." ;;
    del|delete|rm)
      sudo route -n delete "$kind" "$target" >/dev/null || die "경로를 지우지 못했어요: $cidr"
      info "지웠어요: $cidr" ;;
    list|ls)
      route_list ;;
    *)
      die "route add | del | list 중 하나를 쓰세요." ;;
  esac
}

cmd_proxy() {
  local port=${1:-1080}
  need_user
  if port_open "$port"; then die "127.0.0.1:$port 를 이미 다른 프로그램이 쓰고 있어요."; fi
  info "SOCKS5 프록시 127.0.0.1:$port -> $VM_USER@$VM_IP -> Wi-Fi B  (끝내려면 Ctrl+C)"
  say "  Wi-Fi B 전용 브라우저 : 다른 터미널 창에서 ./wifigw-mac.sh browser $port"
  say "  터미널 명령           : curl --socks5-hostname 127.0.0.1:$port $IP_ECHO"
  say "                          export ALL_PROXY=socks5h://127.0.0.1:$port"
  exec ssh -N -D "127.0.0.1:$port" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 $SSH_BASE "$VM_USER@$VM_IP"
}

cmd_browser() {
  local port=${1:-1080} url=${2:-$IP_ECHO} app="" a
  port_open "$port" || die "프록시가 꺼져 있어요. 다른 터미널 창에서 먼저: ./wifigw-mac.sh proxy $port"
  for a in "Google Chrome" "Microsoft Edge" "Brave Browser" "Chromium"; do
    if [ -d "/Applications/$a.app" ] || [ -d "$HOME/Applications/$a.app" ]; then app=$a; break; fi
  done
  [ -n "$app" ] || die "Chrome 계열 브라우저가 없어요. Firefox라면 네트워크 설정에서 SOCKS v5 127.0.0.1:$port 를 넣고 'Proxy DNS when using SOCKS v5' 를 켜세요."
  mkdir -p "$CONF_DIR/browser-profile"
  info "$app 를 Wi-Fi B 전용 프로필로 열어요 (평소 브라우저와 쿠키·로그인이 분리돼요)."
  open -na "$app" --args --user-data-dir="$CONF_DIR/browser-profile" \
    --proxy-server="socks5://127.0.0.1:$port" --no-first-run --no-default-browser-check "$url"
}

cmd_wg_fetch() {
  local dir=${1:-$HOME/wifigw-wireguard}
  need_user
  mkdir -p "$CONF_DIR" "$dir"
  chmod 700 "$dir"
  ssh $SSH_MUX "$VM_USER@$VM_IP" 'cd wifigw && tar -cf - wifiB-*.conf' | tar -xf - -C "$dir" ||
    die "가져오지 못했어요. 먼저 ./wifigw-mac.sh vm --wireguard 를 실행했나요?"
  chmod 600 "$dir"/*.conf
  info "WireGuard 설정을 $dir 에 받았어요."
  say "  wifiB-lan.conf : Wi-Fi B 대역만 VM으로 (인터넷은 Wi-Fi A 그대로)"
  say "  wifiB-all.conf : 모든 IPv4 인터넷을 Wi-Fi B로"
  say "WireGuard 앱 → Import tunnel(s) from file 로 추가하세요. 둘은 같은 키를 쓰니 한 번에 하나만 켜세요."
  if [ ! -d /Applications/WireGuard.app ]; then say "  (WireGuard 앱은 App Store에서 설치할 수 있어요)"; fi
}

cmd_status() {
  local a b wg
  say "VM 설정 : ${VM_USER:-?}@${VM_IP:-?}  ($CONF)"
  if [ -n "$VM_IP" ]; then
    if vm_alive; then say "VM 응답 : OK"; else say "VM 응답 : 없음 (VM이 꺼져 있나요?)"; fi
    say "VM을 거치는 경로:"
    route_list
  fi
  a=$(curl -s --max-time 5 "$IP_ECHO" || true)
  say "공인 IP, 맥 기본 경로     : ${a:-확인 실패}"
  if port_open 1080; then
    b=$(curl -s --max-time 8 --socks5-hostname 127.0.0.1:1080 "$IP_ECHO" || true)
    say "공인 IP, 프록시(Wi-Fi B) : ${b:-확인 실패}"
  else
    say "프록시 127.0.0.1:1080    : 꺼져 있음"
  fi
  wg=$(scutil --nc list 2>/dev/null | grep -i wireguard || true)
  if [ -n "$wg" ]; then say "WireGuard 터널:"; say "$wg"; fi
}

# ------------------------------------------------------- 로그인 자동 시작
autostart_body() {   # launchd 가 로그인 때 실행하는 스크립트 본문 (VM, DONGLE 은 앞에 붙임)
  cat <<'EOF'
# wifigw-autostart: started at login by launchd (made by "wifigw-mac.sh autostart install").
# Starts the UTM VM once, then keeps the USB Wi-Fi dongle attached to it while it runs
# (after a VM restart, a Mac sleep/wake, or re-plugging). It never restarts a VM or UTM
# that you stopped yourself.
UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
CONF="$HOME/.config/wifigw/config"
VM_IP=$(sed -n 's/^VM_IP=//p' "$CONF" 2>/dev/null | tail -n 1)
VM_USER=$(sed -n 's/^VM_USER=//p' "$CONF" 2>/dev/null | tail -n 1)
log()      { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
vm_ssh()   { ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=accept-new \
               -o UserKnownHostsFile="$HOME/.config/wifigw/known_hosts" "$VM_USER@$VM_IP" "$@" 2>/dev/null; }
vm_state() { "$UTMCTL" status "$VM" 2>/dev/null; }
notify()   { osascript -e "display notification \"$1\" with title \"wifigw\"" >/dev/null 2>&1; }
only_this_vm_running() {   # true when no VM other than $VM is running in UTM
  "$UTMCTL" list 2>/dev/null | awk -v vm="$VM" 'NR > 1 { n = $3; for (i = 4; i <= NF; i++) n = n " " $i
    if ($2 != "stopped" && n != vm) other = 1 } END { exit other }'
}
restart_utm() {            # stop the VM cleanly, restart UTM in the background, start the VM again
  "$UTMCTL" stop "$VM" --request >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ "$(vm_state)" = stopped ] && break; sleep 1; done
  [ "$(vm_state)" = stopped ] || "$UTMCTL" stop "$VM" --force >/dev/null 2>&1
  osascript -e 'tell application "UTM" to quit' >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do pgrep -x UTM >/dev/null || break; sleep 1; done
  open -gja UTM; sleep 5
  "$UTMCTL" start --hide "$VM" >/dev/null 2>&1 || log "could not start $VM after restarting UTM"
}

[ -x "$UTMCTL" ] || { log "UTM not found at $UTMCTL"; exit 1; }
[ -n "$VM_IP" ] && [ -n "$VM_USER" ] || { log "no VM address in $CONF (run: wifigw-mac.sh setup)"; exit 1; }

# 1) once, at login: start the VM, with UTM in the background
if ! pgrep -x UTM >/dev/null; then open -gja UTM; sleep 5; fi
if [ "$(vm_state)" = stopped ]; then
  log "starting VM $VM"
  "$UTMCTL" start --hide "$VM" >/dev/null 2>&1 || log "could not start $VM"
fi
log "watching VM $VM (now: $("$UTMCTL" status "$VM" 2>&1 | head -n 1)), dongle $DONGLE"

# 2) while the VM runs: put the dongle back when it is missing
last_try=0 fails=0 last_restart=0
while :; do
  sleep 30
  pgrep -x UTM >/dev/null || continue                              # UTM quit: leave it alone
  [ "$(vm_state)" = started ] || continue                           # VM stopped: leave it alone
  vm_ssh 'ls /sys/class/net' | grep -q '^wl' && { fails=0; continue; }   # dongle already in the VM
  vm_ssh true || continue                                           # VM still booting
  now=$(date +%s)
  [ $((now - last_try)) -ge 90 ] || continue                        # don't hammer a failing dongle
  "$UTMCTL" usb list 2>/dev/null | grep -qi "$DONGLE" || continue   # dongle not plugged in
  last_try=$now
  log "attaching dongle $DONGLE to $VM"
  if "$UTMCTL" usb connect "$VM" "$DONGLE" >/dev/null 2>&1; then fails=0; continue; fi
  fails=$((fails + 1))
  log "attach failed ($fails)"
  [ "$fails" -eq 3 ] || continue
  # After a dongle leaves a VM, UTM can keep a dead entry for it on the same USB location, and
  # every attach then picks that entry. Only restarting UTM clears it - do that only when no other
  # VM would be stopped, and at most every 30 minutes.
  if only_this_vm_running && [ $((now - last_restart)) -ge 1800 ]; then
    log "restarting UTM and $VM to clear UTM's USB device list"
    notify "동글을 VM에 다시 붙이려고 UTM과 VM을 재시작해요."
    restart_utm
    last_restart=$(date +%s) fails=0
  else
    notify "동글을 VM에 다시 붙이지 못했어요. 동글을 뽑았다가 다시 꽂거나 UTM을 재시작해 주세요."
  fi
done
EOF
}

cmd_autostart() {
  local sub=${1:-status} vm=${2:-wifigw} dongle=${3:-0BDA:B812} uid
  local agent="$HOME/Library/LaunchAgents/$AUTOSTART_LABEL.plist" bin="$CONF_DIR/wifigw-autostart"
  local logf="$HOME/Library/Logs/wifigw-autostart.log"
  uid=$(id -u)
  case $sub in
    install)
      need_user
      [ -x "$UTMCTL" ] || die "UTM이 없어요: $UTMCTL"
      mkdir -p "$CONF_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
      { printf '#!/bin/bash\nVM=%q\nDONGLE=%q\n' "$vm" "$dongle"; autostart_body; } > "$bin"
      chmod 755 "$bin"
      cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$AUTOSTART_LABEL</string>
	<key>ProgramArguments</key><array><string>$bin</string></array>
	<key>RunAtLoad</key><true/>
	<key>ProcessType</key><string>Background</string>
	<key>StandardOutPath</key><string>$logf</string>
	<key>StandardErrorPath</key><string>$logf</string>
</dict>
</plist>
EOF
      launchctl bootout "gui/$uid/$AUTOSTART_LABEL" >/dev/null 2>&1 || true
      launchctl bootstrap "gui/$uid" "$agent" || die "launchctl 로 등록하지 못했어요: $agent"
      info "자동 시작을 켰어요: 로그인하면 VM '$vm' 을 켜고, 동글($dongle)이 빠지면 30초 안에 다시 붙여요."
      say "  기록: $logf"
      say "  끄기: ./wifigw-mac.sh autostart uninstall" ;;
    uninstall|remove)
      launchctl bootout "gui/$uid/$AUTOSTART_LABEL" >/dev/null 2>&1 || true
      rm -f "$agent" "$bin"
      info "자동 시작을 껐어요. (VM과 동글 연결은 그대로 둬요)" ;;
    status)
      if launchctl print "gui/$uid/$AUTOSTART_LABEL" >/dev/null 2>&1; then
        say "자동 시작: 켜짐 ($(launchctl print "gui/$uid/$AUTOSTART_LABEL" | awk -F'= ' '/^[[:space:]]*state =/ { print $2; exit }'))"
      else
        say "자동 시작: 꺼짐"
      fi
      if [ -f "$logf" ]; then say "최근 기록:"; tail -n 5 "$logf" | sed 's/^/  /'; fi ;;
    *)
      die "autostart install | uninstall | status 중 하나를 쓰세요." ;;
  esac
}

main() {
  local cmd=${1:-help}
  if [ $# -gt 0 ]; then shift; fi
  case $cmd in
    setup)          cmd_setup "$@" ;;
    vms)            list_vms ;;
    vm)             cmd_vm "$@" ;;
    push)           cmd_push ;;
    route)          cmd_route "$@" ;;
    proxy)          cmd_proxy "$@" ;;
    browser)        cmd_browser "$@" ;;
    wg-fetch)       cmd_wg_fetch "$@" ;;
    status)         cmd_status ;;
    autostart)      cmd_autostart "$@" ;;
    help|-h|--help) usage ;;
    *)              die "모르는 명령이에요: $cmd  (./wifigw-mac.sh help)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
