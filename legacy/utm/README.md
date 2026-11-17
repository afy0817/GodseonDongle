# wifigw: UTM VM으로 맥에서 Wi-Fi 두 개 쓰기

> 먼저 만든 방식이에요. 지금은 GodseonDongle 앱(이 저장소의 루트)으로 바꿨어요. 바꿀 때는 UTM 자동 시작이 로그인 때 VM을 켜서 동글을 두고 다투지 않게 꺼 두세요(되돌리기는 `launchctl enable`).
>
> ```bash
> launchctl bootout gui/$(id -u)/local.wifigw.autostart; launchctl disable gui/$(id -u)/local.wifigw.autostart
> ```

맥 내장 Wi-Fi(**Wi-Fi A**)는 그대로 쓰고, USB Wi-Fi 동글을 UTM 리눅스 VM에 넘겨 다른 Wi-Fi(**Wi-Fi B**)에 붙인 뒤, 맥이 그 VM을 공유기처럼 거쳐 Wi-Fi B를 쓰게 만드는 스크립트예요.

```
맥 내장 Wi-Fi ──────────────────────────────── Wi-Fi A (기본 인터넷)
USB 동글 ─(UTM USB 패스스루)→ Linux VM ─────── Wi-Fi B
                                 │ NAT + 방화벽
맥 ←── UTM Shared Network (예: 192.168.64.x) ──┘
       경로 추가 / SOCKS 프록시 / WireGuard 중 골라서 원하는 트래픽만 VM으로
```

| 파일 | 실행 위치 | 하는 일 |
|---|---|---|
| `wifigw-vm.sh` | VM 안 (root) | 동글로 Wi-Fi B 접속, VM의 인터넷을 Wi-Fi B로만 보내기, 포워딩·NAT, Wi-Fi B 쪽에서 들어오는 연결 차단, (선택) WireGuard 서버 |
| `wifigw-mac.sh` | 맥 터미널 | VM 주소 저장, VM 스크립트 복사·실행, 경로 추가, SOCKS 프록시, 전용 브라우저, WireGuard 설정 받기 |

## 1. UTM에 VM 만들기

1. UTM 설치: <https://mac.getutm.app> 또는 `brew install --cask utm`
2. **Create a New Virtual Machine → Virtualize → Linux**
   - **Use Apple Virtualization은 끈 채로** 두세요. QEMU 백엔드여야 USB 패스스루가 돼요.
   - 설치 ISO: **Ubuntu Server 24.04 LTS (ARM64)** 또는 **Debian 13 (arm64 netinst)**
   - 메모리 384MB, CPU 1개, 디스크 3GB면 충분해요(VM 안에서 120MB 남짓 써요). 화면 장치는 빼도 돼요. 접속은 SSH나 시리얼 콘솔로 해요.
3. 설치할 때 **OpenSSH 서버를 꼭 고르세요** (Ubuntu: "Install OpenSSH server", Debian: "SSH server").
4. 설치가 끝나면 VM을 끄고 설정에서:
   - **Network**: Shared Network (기본값 그대로)
   - **Input**: USB Support를 **USB 3.0 (XHCI)** 로, **Share USB devices from host** 켜기

## 2. 설정 실행

VM을 켠 상태에서, 맥 터미널로 이 폴더에 들어가서:

```bash
chmod +x wifigw-mac.sh
./wifigw-mac.sh setup            # VM IP 목록에서 고르고 로그인 계정 입력
./wifigw-mac.sh vm --wireguard   # VM으로 스크립트를 복사하고 실행 (sudo 비밀번호 → Wi-Fi 선택 → 비밀번호)
```

- 스크립트가 `No Wi-Fi interface in the VM yet` 이라고 하면 그때 동글을 넘기세요: **UTM 툴바의 USB 아이콘 → `Realtek 802.11ac NIC`**.
- Realtek 동글(rtw88 드라이버)은 USB 2 모드로 고정해요. 최신 커널의 rtw88은 동글을 USB 3 모드로 바꾸는데, 그 순간 장치가 끊겼다 다시 잡히면서 UTM 패스스루에서 빠지기 때문이에요. USB 3을 쓰고 싶으면 `--usb3`.
- 다시 실행해도 안전해요. Wi-Fi B를 바꿀 때도 그냥 다시 실행하면 돼요.
- DHCP가 없는 망(장비망 등)은 고정 IP를 같이 넘기세요. 예: `./wifigw-mac.sh vm --wireguard --ssid LabNet --ip 192.168.50.20/24 --gw 192.168.50.1 --route "10.10.0.0/24 192.168.50.254"`
- VM 콘솔에서 직접 돌려도 돼요: `sudo bash wifigw-vm.sh --wireguard`

VM 스크립트 옵션 (`./wifigw-mac.sh vm` 뒤에 붙이면 그대로 전달돼요):

| 옵션 | 뜻 |
|---|---|
| `--ssid 이름` | 접속할 Wi-Fi B (생략하면 스캔 목록에서 입력) |
| `--password 비번` / `--open` | 비밀번호 / 비밀번호 없는 네트워크 (생략하면 숨김 입력으로 물어봄) |
| `--hidden` | 이름을 숨긴 네트워크 |
| `--ip 주소/접두어` | DHCP가 없는 망의 고정 IP. 예: `--ip 192.168.50.20/24` (접두어를 빼면 /24) |
| `--gw IP`, `--dns "IP,IP"` | 고정 IP일 때 게이트웨이와 DNS (둘 다 선택) |
| `--route "대역 게이트웨이"` | 그 망 안의 다른 라우터 너머 대역. 여러 번 쓸 수 있어요. 예: `--route "10.10.0.0/24 192.168.50.254"` |
| `--keep-wifi` | 접속은 건너뛰고 이미 연결된 Wi-Fi를 그대로 사용 (802.1X처럼 `nmcli`로 직접 붙인 경우) |
| `--wireguard` | WireGuard 서버와 맥용 설정 파일 생성 |
| `--wifi IF`, `--lan IF` | 인터페이스 직접 지정 (보통 자동으로 찾음) |
| `--usb3` | Realtek 동글의 USB 3 모드 전환 허용 |
| `status`, `uninstall` | 상태 보기, 설정 되돌리기 |

## 3. 맥에서 Wi-Fi B 쓰기

### A. 특정 대역만 (IoT 기기 AP, 사내망 등)

```bash
./wifigw-mac.sh route add 192.168.50.0/24   # VM 스크립트가 마지막에 알려준 Wi-Fi B 대역
./wifigw-mac.sh route del 192.168.50.0/24
```

인터넷은 Wi-Fi A 그대로 쓰고 그 대역만 Wi-Fi B로 가요. 맥이 지금 붙어 있는 대역과 겹치면 거부해요(지금 쓰는 네트워크가 끊길 수 있어서). VM을 끄거나 맥을 재부팅하면 경로가 사라져요.

### B. 특정 앱만 (SOCKS 프록시)

```bash
./wifigw-mac.sh proxy     # 이 창은 열어 두기 (Ctrl+C로 종료)
./wifigw-mac.sh browser   # 다른 창에서: Wi-Fi B 전용 Chrome 창
```

- 전용 Chrome 창은 별도 프로필이라 평소 Chrome과 쿠키·로그인이 섞이지 않아요. 처음 열리는 페이지에 Wi-Fi B 쪽 공인 IP가 보여요.
- 터미널 프로그램: `curl --socks5-hostname 127.0.0.1:1080 …` 또는 `export ALL_PROXY=socks5h://127.0.0.1:1080`

### C. WireGuard (자주 쓸 때 추천)

```bash
./wifigw-mac.sh wg-fetch   # ~/wifigw-wireguard 에 설정 파일 2개 저장
```

App Store에서 WireGuard 앱을 설치하고 **Import tunnel(s) from file** 로 추가한 다음 켜고 끄기만 하면 돼요. 라우팅과 DNS는 앱이 알아서 잡아요.

- `wifiB-lan.conf`: Wi-Fi B 대역만 VM으로 (A와 같은 효과인데 켜고 끄기가 편함)
- `wifiB-all.conf`: 모든 IPv4 인터넷을 Wi-Fi B로 (DNS도 Wi-Fi B 것을 사용)

두 파일은 같은 키를 쓰니까 한 번에 하나만 켜세요.

- 파일 이름이 터널 이름이 돼요. 예를 들어 `wifiB-lan.conf`를 `LabNet.conf`로 복사해서 가져오면 터널 이름이 `LabNet`이 돼요.
- 가져오기는 앱의 **Import tunnel(s) from file**로 하세요. Finder에서 파일을 WireGuard로 여는 것만으로는 안 들어가요. 처음 한 번은 macOS가 VPN 구성 추가를 허용할지 물어요.
- 터널을 켜면 `route add`로 넣었던 같은 대역 경로는 터널이 대신 차지해요. sudo가 더 필요 없고, VM을 재시작해도 VM이 돌아오면 터널이 저절로 다시 붙어요.
- 맥을 재부팅한 뒤에도 자동으로 켜지게 하려면, 앱에서 터널을 편집해 **On-Demand**(Wi-Fi·Ethernet)를 켜세요.
- 터미널에서 켜고 끄기: `scutil --nc start LabNet` / `scutil --nc stop LabNet`

### 확인

```bash
./wifigw-mac.sh status      # VM 응답, 경로, 맥 기본 경로 vs Wi-Fi B 공인 IP
./wifigw-mac.sh vm status   # VM 쪽: Wi-Fi B 주소, 기본 경로, NAT, WireGuard
```

### 자동 시작 (로그인하면 VM 켜기 + 동글 자동 연결)

```bash
./wifigw-mac.sh autostart install     # 기본: VM 이름 wifigw, 동글 0BDA:B812
./wifigw-mac.sh autostart status
./wifigw-mac.sh autostart uninstall
```

- 로그인하면 UTM을 백그라운드로 열고 VM을 켜요. 그 뒤로는 30초마다 확인해서 동글이 VM에서 빠져 있으면 다시 붙여요. VM 재시작, 잠자기 후, 동글을 다시 꽂았을 때가 해당돼요.
- VM이나 UTM을 직접 끄면 다시 켜지 않아요. 켜는 건 로그인할 때 한 번뿐이에요. ThruRNDIS-Wi-Fi로 바꿔 쓸 때는 VM만 끄면 돼요.
- 동글이 VM에서 빠진 뒤 UTM이 죽은 USB 항목을 남기면 연결이 계속 실패해요. 이때는 3번 실패한 뒤 UTM과 VM을 한 번 재시작해서 복구해요. 다른 VM이 돌고 있지 않을 때만, 30분에 한 번까지 하고, 맥 알림으로 알려 줘요. 다른 VM이 돌고 있으면 동글을 다시 꽂으라는 알림만 보내요.
- 설치되는 파일: `~/.config/wifigw/wifigw-autostart`, `~/Library/LaunchAgents/local.wifigw.autostart.plist` (기록: `~/Library/Logs/wifigw-autostart.log`)
- 이 폴더가 없어져도 손으로 끌 수 있어요: `launchctl bootout gui/$(id -u)/local.wifigw.autostart` 를 실행한 뒤 위 두 파일을 지우세요.
- WireGuard 터널의 On-Demand까지 켜 두면, 재부팅한 뒤 아무것도 하지 않아도 Wi-Fi B 쪽 망에 닿아요.

## 문제 해결

| 증상 | 확인할 것 |
|---|---|
| UTM USB 메뉴에 동글이 없음 | VM 설정 Input에서 USB Sharing이 켜져 있는지, VM이 QEMU 백엔드인지 (Apple Virtualization VM에는 USB 메뉴가 없어요) |
| VM에 Wi-Fi 인터페이스가 안 생김 | VM에서 `lsusb`로 `0bda:b812`가 보이는지, `sudo dmesg \| grep -i rtw`. 펌웨어가 없으면 스크립트가 펌웨어 패키지를 설치하는데, Debian은 apt 소스에 `non-free-firmware`가 있어야 해요 |
| 동글이 자꾸 빠짐 | 맥이 잠자기에서 깨면 UTM에서 다시 넘겨 주세요. `--usb3`를 썼다면 빼고 다시 실행 |
| `route add`가 거부됨 | Wi-Fi A와 같은 대역이에요. 프록시나 WireGuard `wifiB-all`을 쓰세요 |
| 호텔·카페 로그인 페이지 | `proxy`를 켜고 `browser`로 아무 `http://` 사이트를 열면 로그인 페이지가 Wi-Fi B 쪽으로 떠요 |
| VM 인터넷이 Wi-Fi A로 나가는 것 같음 | `./wifigw-mac.sh vm status`에서 Default routes에 Wi-Fi 인터페이스(wl…)만 있어야 해요 |
| Wi-Fi는 붙는데 `IP configuration could not be reserved` | DHCP가 없는 망이에요. `--ip`, `--gw`, `--route`로 고정 IP를 주세요. 등록된 기기에만 IP를 주는 망이면 동글 MAC 등록이 필요해요 |
| 입력이 `ㅒㅣ`처럼 한글로 들어감, sudo가 비밀번호를 거부 | 입력기를 영문으로 바꾸세요. 잘못 친 줄은 Ctrl+U로 한 번에 지워요 |
| `utmctl usb connect`가 `No such device`로 실패 | UTM이 죽은 USB 항목을 남긴 경우예요. `utmctl usb list`에 같은 동글이 두 줄로 보여요. UTM을 재시작하면 지워져요. 자동 시작 에이전트는 이걸 알아서 해요. 참고로 `utmctl usb disconnect`는 VM 이름 없이 장치만 받아요 |
| ThruRNDIS-Wi-Fi도 같이 씀 | 동글은 한 번에 한 VM에만 붙고, 같은 대역 경로도 겹쳐요. 둘을 동시에 켜지 마세요 |

## 되돌리기

- VM: `./wifigw-mac.sh vm uninstall` (설치한 패키지는 남겨 둬요)
- 맥: `./wifigw-mac.sh route del <대역>`, WireGuard 앱에서 터널 삭제, `rm -rf ~/.config/wifigw ~/wifigw-wireguard`

## 알아둘 점

- USB 패스스루와 NAT를 거치기 때문에 동글을 직접 쓸 때보다 느리고 지연이 늘어요.
- 두 회선 속도를 합치지는 못해요. 목적지별·앱별로 나눠 쓰는 것만 돼요.
- NAT 너머라 AirPlay·프린터 같은 자동 검색(mDNS)은 안 돼요. IP로 직접 접속하세요.
- WireGuard `wifiB-all`은 IPv4만 터널로 보내요. Wi-Fi A에 IPv6가 있으면 IPv6 트래픽은 Wi-Fi A로 나갈 수 있어요.
- VM의 SSH와 WireGuard는 맥 쪽(Shared Network)에서만 받아요. Wi-Fi B 쪽에서 새로 들어오는 연결은 VM 방화벽이 막아요.
- VM 스크립트는 망 설정을 바꾸는 중에 SSH가 잠깐 멈출 수 있어요. 끊겨도 스크립트는 VM에서 끝까지 돌아요. 걱정되면 VM 콘솔에서 실행하세요.
