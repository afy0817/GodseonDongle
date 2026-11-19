# GodseonDongle

[![build](https://github.com/afy0817/GodseonDongle/actions/workflows/build.yml/badge.svg)](https://github.com/afy0817/GodseonDongle/actions/workflows/build.yml)

GodseonDongle is a macOS app that keeps the Mac's built-in Wi-Fi as it is and joins a second
Wi-Fi network at the same time through a USB Wi-Fi dongle — handy for equipment or lab networks
that have no internet. A small root helper captures the dongle and hands it over USB/IP to a tiny
Linux VM (Virtualization.framework) that the app runs; Linux drives the dongle with its in-tree
driver, and the Mac routes that network's subnets through the VM. The same way it can use an
Android phone's USB tethering (RNDIS, which macOS has no driver for) as the Mac's internet, next
to the dongle. No UTM, no kernel extension, no Apple developer account. The app speaks Korean and
English (Settings > Language); the rest of this README is in Korean.

맥 내장 Wi-Fi는 그대로 쓰면서 USB Wi-Fi 동글로 다른 Wi-Fi(장비망 등)에 동시에 붙게 해 주는 macOS 앱이에요. 안드로이드 폰의 USB 테더링(RNDIS)도 동글과 함께 맥의 인터넷으로 쓸 수 있어요. UTM, ThruRNDIS, WireGuard 같은 다른 앱 없이 혼자 돌아가요.

## 구조

```
GodseonDongle.app
 ├ 창: 장치 목록 · Wi-Fi 목록 · 비밀번호 · IP · 경로        상단바: 아이콘만
 └ VM: Virtualization.framework, 램에서만 도는 리눅스 (256MB)
        eth0(VZ NAT) ── 제어 API :9408
        wlan0(동글) ── 표 100      usb0(폰 테더링) ── 표 101, NAT, DNS 프록시
godseon-dongled  (root 도우미, launchd)
 ├ USB/IP 서버 :9408 ── 동글(버스 1-1)과 폰(1-2)을 가져와 VM에 넘겨요
 ├ 맥 경로: 동글 쪽 대역 → VM
 └ 폰 인터넷: 브리지에 10.94.8.2/30 + 네트워크 서비스(기본 경로·DNS → VM 10.94.8.1)
```

- **장치 목록:** 창 왼쪽에 지원하는 동글과 안드로이드 폰이 보여요. 장치마다 쓸지, 동글은 Trigger 프레임 거르기, 폰은 맥 인터넷으로 쓸지를 정해요. 동글과 폰은 종류마다 하나씩 동시에 쓸 수 있어요. 설정은 장치별로 저장되고, 폰은 일련번호로 알아봐요(테더링을 켜면 USB ID가 바뀌어서요).
- **동글:** 도우미가 IOUSBHost로 동글을 가져와 USB/IP로 VM에 넘겨요. root라서 다른 앱이 잡고 있어도 가져와요. Apple 개발자 계정이나 제한 권한은 필요 없어요.
- **폰 테더링:** 폰에서 USB 테더링을 켜면 도우미가 그 폰을 가져와 VM에 넘기고, VM의 리눅스 `rndis_host`가 `usb0`으로 받아요. 테더링을 끈 폰은 macOS에 그대로 남아요(파일 전송, adb).
  - **맥 인터넷:** 켜 두면 도우미가 VM 브리지에 호스트 링크 `10.94.8.2/30`을 더하고, 그 주소로 네트워크 서비스를 만들어 macOS가 맨 앞에 두게 해요(VPN처럼 `OverridePrimary`). 그래서 기본 경로와 DNS가 VM(`10.94.8.1`)을 거쳐 폰으로 가요. 내장 Wi-Fi는 연결된 채로 남고, 동글 쪽 대역은 그대로 동글로 가요.
  - VM은 맥이 보낸 주소로 길을 나눠요. 브리지 주소에서 온 건 동글(`wlan0`)로, `10.94.8.2`에서 온 건 폰(`usb0`)으로 보내요.
  - 이 서비스는 임시 항목이라 도우미가 죽어도 macOS가 바로 지워요. 폰을 뽑거나 앱을 끄면 도우미가 1~2초 안에 거둬요.
  - Pixel 6 이후처럼 USB 테더링에 NCM을 쓰는 폰은 macOS가 직접 써서 이 앱이 필요 없어요. 갤럭시 등 RNDIS를 쓰는 폰을 위한 기능이에요.
- **VM:** 앱이 직접 띄워요. 앱 서명에는 `com.apple.security.virtualization` 하나만 있으면 되고, ad-hoc 서명으로 충분해요.
- **Wi-Fi:** 비밀번호는 맥 키체인에 저장해요. VM에는 맥에서 계산한 PSK만 넘어가요.
- **맥 경로:** 연결한 Wi-Fi의 대역과 네트워크별 추가 경로를 VM으로 보내요.
  - 맥의 다른 네트워크(내장 Wi-Fi 등)와 겹치는 대역은 빼요.
  - 이미 다른 연결(VPN 등)이 쓰는 대역은 건드리지 않고 "충돌"로 보여 줘요.
- **송신 멈춤 대비:** 동글로 보내는 요청이 6초 넘게 멈추면 도우미가 먼저 그 통로를 비워요. 그래도 안 풀리면 동글을 재설정하고, VM이 약 15초 뒤 다시 붙어요.
- **앱을 끄면:** 동글과 폰을 macOS에 돌려주고 맥 경로와 폰 인터넷을 지워요. 창만 닫으면 상단바 아이콘으로 계속 돌아가요.

동글은 VM 안의 리눅스 드라이버가 맡아요. 넣어 둔 드라이버는 [vm/drivers.conf](vm/drivers.conf)에 있어요(rtw88, rtw89, mt76, rtl8xxxu, rt2800usb, ath9k_htc 등). 실제로 시험한 동글은 RTL8812BU(`0bda:b812`)예요.

## 빌드

macOS 14 이상, Xcode(SwiftUI 매크로 때문), Docker(VM 이미지를 처음 만들 때)가 필요해요.

```bash
./app/build_app.sh
```

```bash
./app/build_app.sh --install
```

`vm/`이 바뀌면 `build_app.sh`가 `dist/vm_assets/manifest.json`에 남은 해시로 알아채고 VM 이미지를 다시 만들어요(`GODSEON_REBUILD_VM=0`이면 그대로 둬요). 언제나 다시 만들려면:

```bash
GODSEON_REBUILD_VM=1 ./app/build_app.sh
```

결과물은 `dist/GodseonDongle.app`(약 58MB)이고, `--install`을 붙이면 `/Applications`에 복사해요.

GitHub Actions([.github/workflows/build.yml](.github/workflows/build.yml))도 같은 앱을 빌드해요. VM 이미지는 리눅스 arm64 러너의 Docker에서, 앱은 맥 러너에서 만들고, 실행마다 zip을 아티팩트로 남겨요. `v`로 시작하는 태그(예: `v0.1.0`)를 올리면 Release에 zip이 붙어요. 내려받은 앱은 ad-hoc 서명이라 처음 열 때 macOS가 막아요. Finder에서 오른쪽 클릭 → **열기**를 누르거나 아래 명령을 실행해요.

```bash
xattr -dr com.apple.quarantine /Applications/GodseonDongle.app
```

새로 빌드한 앱은 ad-hoc 서명이 바뀌어서, 처음 저장된 Wi-Fi에 붙을 때 macOS가 키체인의 비밀번호를 이 앱에 줘도 되는지 한 번 물어요. **항상 허용**을 누르면 돼요.

## 처음 실행

1. 앱을 열고 **도우미 설치**를 눌러요. 관리자 암호는 macOS가 직접 물어요.
2. 동글을 꽂으면 **장치** 목록에 보이고, 도우미가 가져와 VM에 붙여요. 처음 꽂은 동글은 바로 써요.
3. 목록에서 Wi-Fi를 고르고 비밀번호와 IP 설정을 넣은 뒤 **연결**을 눌러요.
4. 고정 IP 네트워크라면 **직접 입력**을 체크하고 IP·서브넷·게이트웨이와 추가 경로(예: `10.10.0.0/24 → 192.168.50.254`)를 넣어요. 체크를 풀면 자동(DHCP)으로 받고, 적어 둔 값은 남아 있어요.
5. 설정에서 **로그인할 때 열기**를 켜면 로그인할 때 저절로 떠요. 저장된 네트워크에는 자동으로 다시 붙어요.

- 목록 맨 위 **현재 상태**를 누르면 연결, 폰, 맥 경로, USB/IP 상태를 다시 볼 수 있어요.
- **폰 테더링:** 폰을 꽂으면 **장치** 목록에 보여요. 폰을 골라 **USB 테더링을 켜면 VM에 넘기기**를 켜고, 폰에서 USB 테더링을 켜요(갤럭시: 설정 > 연결 > 모바일 핫스팟 및 테더링). **맥 인터넷을 이 폰으로**는 처음부터 켜져 있어요. 예전 앱으로 도우미를 설치했다면 설정의 **도우미 업데이트**를 먼저 눌러요.
- 비밀번호 칸의 눈 버튼을 누르면 친 글자가 보이고 입력기도 바꿀 수 있어요. 저장된 비밀번호는 Touch ID나 맥 암호로 확인한 뒤 볼 수 있어요.
- 설정의 **언어**에서 시스템 설정 따름, 한국어, English를 고를 수 있어요. 바로 바뀌어요.
- 앱을 업데이트한 뒤 설정에 **도우미 업데이트**가 보이면 눌러요(관리자 암호).

## 포트

이 프로젝트는 **9408**만 써요. 8080, 5000 같은 흔한 포트는 쓰지 않아요.

| 어디 | 무엇 |
|---|---|
| 맥 `0.0.0.0:9408` | 도우미의 USB/IP 서버. 앱이 띄운 VM 주소에서 오는 연결만 받아요 |
| VM `eth0:9408` | 제어 API. 맥 쪽 연결만 받고, 부팅마다 바뀌는 토큰이 필요해요 |

주소는 VZ NAT 대역 말고 폰 인터넷용 호스트 링크 `10.94.8.0/30` 하나만 써요(맥 `10.94.8.2`, VM `10.94.8.1`). 맥의 다른 인터페이스가 이 대역을 쓰고 있으면 도우미가 폰 인터넷을 켜지 않고 오류로 알려요.

## 지금 상태 (2026-11-19)

- **안드로이드 USB 테더링:** 실제 폰(갤럭시, RNDIS)으로 확인했어요.
  - 동글과 폰을 함께 VM에 붙여요(버스 1-1, 1-2). 동글 대역은 `wlan0`으로, 인터넷은 `usb0`으로 따로 가요.
  - **맥 인터넷을 이 폰으로**를 켜면 macOS가 폰 쪽 네트워크 서비스를 맨 앞에 둬요(`OverridePrimary`). 맥에서 올린 2MB·20MB가 52~59Mbit/s로 갔어요.
  - 처음에는 맥에서 폰 인터넷으로 올리면 약 130KB에서 서버가 연결을 끊었어요. vmnet 브리지가 TSO를 내세워서 맥이 최대 64KB짜리 TCP 덩어리를 VM에 넘기는데, `usb0`(rndis_host)로는 그 일부만 갔어요. ThruRNDIS는 맥 쪽이 TSO 없는 feth라 이 일이 없어요. 브리지 하나만 TSO를 끌 수는 없어서, 폰이 맥 인터넷인 동안 도우미가 맥 전체의 TSO를 꺼요(`net.inet.tcp.tso=0`). 끝나면 원래 값으로 되돌려요.
  - 알려진 점: 폰으로 가는 건 IPv4뿐이에요. 내장 Wi-Fi에 IPv6가 있으면 IPv6 연결은 그대로 Wi-Fi로 가고, 그 IPv6에 인터넷이 없으면 연결이 잠깐 늦어질 수 있어요.
  - VM 안의 방화벽은 업링크에서 나오는 것 중 맥이 시작한 연결의 응답만 넘겨요. 그래서 동글 쪽 망과 폰 쪽 망은 서로에게도, 맥에도 닿지 못해요.

- **동글로 큰 파일 올리기:** 붐비는 채널에서 scp가 보낸 양의 최대 28%를 다시 보내며 1~2Mbit/s로 떨어지고, 끝 무렵 멈추곤 했어요.
  - 맥이 보낸 패킷은 VM과 USB까지 빠짐없이 갔고, 같은 길로 보낸 낱개 ping은 하나도 빠지지 않았어요. 몰아서 보낼 때만 공중에서 빠지는 모양이에요.
  - TSO를 끄고 올리니 400MB가 평균 41Mbit/s, 재전송 0.01%였어요. 다만 그날은 채널이 덜 붐볐어요(동글 송신 속도가 81Mbit/s가 아니라 135~243Mbit/s).
  - 그래서 동글 설정에 **큰 업로드 안정화 · TSO 끄기**를 넣었어요(처음부터 켜짐). 켜 두면 동글을 쓰는 동안 도우미가 맥의 TSO를 끄고, 동글을 그만 쓰면 되돌려요.

- **USB/IP 실험:** 512MB를 올리고 내려받으면서 UTM 방식과 비교했어요. 자세한 결과는 [spike/README.md](spike/README.md)에 있어요.

  | | UTM | USB/IP |
  |---|---|---|
  | 올리기 | 13.2Mbit/s | 13.8Mbit/s |
  | 내려받기 | 11.2Mbit/s | 29.6Mbit/s |
  | 올리는 중 ping 평균 | 554ms | 146ms |

  두 방식 모두 올리기가 약 14Mbit/s에서 막혀요. 동글이 보내기 속도를 낮게(MCS2) 고르는 쪽 한계로 보여요.
- **앱 통합 시험:** 실제 동글로 인터넷이 없는 장비망(WPA2, 5GHz, 고정 IP)에 붙여 확인했어요.
  - 도우미 설치 → 동글 가져오기 → VM에 붙이기까지 3초가 걸렸어요.
  - 고정 IP와 추가 경로로 연결하자 맥 경로 두 개(그 Wi-Fi의 대역, 추가 경로 하나)가 잡혔어요.
  - 맥에서 바로 보낸 128MB는 올리기 13.1Mbit/s, 내려받기 30.7Mbit/s였고 sha256이 일치했어요.
  - 다시 시작하거나 동글을 다시 꽂아도 저장된 네트워크로 저절로 다시 붙었어요(17~22초).
  - 앱을 끄면 1초 안에 동글을 돌려주고 경로를 지웠어요.
- **메모리:** 앱 55MB + 도우미 10MB + VM 약 280MB예요.
- **CPU (쉴 때):** 앱 2% + 도우미 6~10% + VM 14~21%였어요. 앱의 상태 폴링과 VM 안 감시 스크립트는 처음보다 줄였어요.
  - 남은 대부분은 동글이 받는 프레임 수에 비례해요. 쉴 때도 USB 받기 요청이 초당 600~700개였는데, 재 보니 그중 약 90%가 주변 Wi-Fi 6 공유기가 보내는 Trigger 프레임이었어요. 802.11ac 동글은 쓰지 못하는 프레임인데, 칩의 수신 필터를 바꿔도 걸러지지 않았어요([vm/kernel/README.md](vm/kernel/README.md)).
  - 그래서 도우미가 rtw88 동글(RTL8812BU·8822BU·8811CU·8821CU·8812CU·8822CU)의 받기 응답을 보고, Trigger 프레임만 든 응답은 VM에 넘기지 않고 그 요청을 동글에 다시 걸어요. 동글 설정의 **Wi-Fi 6 Trigger 프레임 거르기**로 끌 수 있어요.
  - 거르기를 켠 뒤에는 VM으로 가는 받기 요청이 초당 약 715개에서 약 50개로 줄었고(도우미가 초당 350~430개를 걸러요), CPU는 도우미 약 10% → 5%, VM 약 20% → 6%가 됐어요. 연결과 맥 경로는 그대로 돌아요.
- **알려진 점:** 동글이 한 번 이상한 상태가 돼 올리기가 1.6Mbit/s로 떨어졌어요. 다음에 다시 인식될 때는 USB Full Speed(12Mbit/s)로 잡혔고, 다시 꽂으니 풀렸어요. 지금은 느린 USB 모드면 앱이 경고해요.

## 폴더

| 폴더 | 내용 |
|---|---|
| `app/` | 맥 앱 (SwiftUI, Virtualization). `build_app.sh`로 번들을 만들어요. 아이콘은 `app/icon/make_icon.swift`로 그려요 |
| `app/Resources/*.lproj` | 영어 문자열. 코드의 한국어 문자열이 키예요. `python3 app/tools/check_strings.py`로 빠진 번역을 찾아요 |
| `helper/` | root 도우미 `godseon-dongled` (USB/IP 서버 + 맥 경로 + 폰 인터넷 + Trigger 프레임 거르기 + TSO 끄기), 설치·제거 스크립트 |
| `vm/` | VM 이미지 빌더. ThruRNDIS-Wi-Fi에서 가져와 USB/IP를 더했어요. `vm/kernel/`에 rtw88 패치를 넣어 다시 빌드할 수 있어요 |
| `spike/` | USB/IP 실험 코드와 시험 결과 |
| `legacy/utm/` | 먼저 만든 UTM + WireGuard 방식 |
| `LICENSES/` | MIT(앱·도우미·실험·legacy), GPL-2.0-or-later(VM 이미지 빌더) |

## 개발용 VM 콘솔

`defaults write io.github.afy0817.GodseonDongle DebugConsole -bool true`로 켜고 앱을 다시 시작하면, `~/Library/Application Support/GodseonDongle/console.in`에 쓴 줄이 VM의 root 콘솔에 입력돼요. 결과는 `~/Library/Logs/GodseonDongle/console.log`에 쌓여요. 끄려면 `defaults delete io.github.afy0817.GodseonDongle DebugConsole`을 실행하고 앱을 다시 시작해요.

## 지우기

설정의 **도우미 제거**를 누르거나 `sudo sh helper/uninstall.sh`를 실행한 뒤 앱을 지워요. 저장한 Wi-Fi 비밀번호는 키체인에 "GodseonDongle: 네트워크 이름" 항목으로 남아 있어요.

## 라이선스

파일마다 SPDX 머리말이 있어요. 앱(`app/`), 도우미(`helper/`), `spike/`, `legacy/`는 MIT([LICENSE](LICENSE))이고, ThruRNDIS-Wi-Fi에서 가져온 VM 이미지 빌더(`vm/`)는 GPL-2.0-or-later예요. 라이선스 원문은 [LICENSES/](LICENSES/)에 있어요.
