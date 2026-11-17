# GodseonDongle

GodseonDongle is a macOS app that keeps the Mac's built-in Wi-Fi as it is and joins a second
Wi-Fi network at the same time through a USB Wi-Fi dongle — handy for equipment or lab networks
that have no internet. A small root helper captures the dongle and hands it over USB/IP to a tiny
Linux VM (Virtualization.framework) that the app runs; Linux drives the dongle with its in-tree
driver, and the Mac routes that network's subnets through the VM. No UTM, no kernel extension,
no Apple developer account. The app speaks Korean and English (Settings > Language); the rest of
this README is in Korean.

맥 내장 Wi-Fi는 그대로 쓰면서 USB Wi-Fi 동글로 다른 Wi-Fi(장비망 등)에 동시에 붙게 해 주는 macOS 앱이에요. UTM, ThruRNDIS, WireGuard 같은 다른 앱 없이 혼자 돌아가요.

## 구조

```
GodseonDongle.app
 ├ 창: Wi-Fi 목록 · 비밀번호 · IP · 경로        상단바: 아이콘만
 └ VM: Virtualization.framework, 램에서만 도는 리눅스 (256MB)
        eth0(VZ NAT) ── 제어 API :9408
godseon-dongled  (root 도우미, launchd)
 ├ USB/IP 서버 :9408 ── 동글을 가져와 VM에 넘겨요
 └ 맥 경로: 동글 쪽 대역 → VM
```

- **동글:** 도우미가 IOUSBHost로 동글을 가져와 USB/IP로 VM에 넘겨요. root라서 다른 앱이 잡고 있어도 가져와요. Apple 개발자 계정이나 제한 권한은 필요 없어요.
- **VM:** 앱이 직접 띄워요. 앱 서명에는 `com.apple.security.virtualization` 하나만 있으면 되고, ad-hoc 서명으로 충분해요.
- **Wi-Fi:** 비밀번호는 맥 키체인에 저장해요. VM에는 맥에서 계산한 PSK만 넘어가요.
- **맥 경로:** 연결한 Wi-Fi의 대역과 네트워크별 추가 경로를 VM으로 보내요.
  - 맥의 다른 네트워크(내장 Wi-Fi 등)와 겹치는 대역은 빼요.
  - 이미 다른 연결(VPN 등)이 쓰는 대역은 건드리지 않고 "충돌"로 보여 줘요.
- **송신 멈춤 대비:** 동글로 보내는 요청이 6초 넘게 멈추면 도우미가 먼저 그 통로를 비워요. 그래도 안 풀리면 동글을 재설정하고, VM이 약 15초 뒤 다시 붙어요.
- **앱을 끄면:** 동글을 macOS에 돌려주고 맥 경로를 지워요. 창만 닫으면 상단바 아이콘으로 계속 돌아가요.

동글은 VM 안의 리눅스 드라이버가 맡아요. 넣어 둔 드라이버는 [vm/drivers.conf](vm/drivers.conf)에 있어요(rtw88, rtw89, mt76, rtl8xxxu, rt2800usb, ath9k_htc 등). 실제로 시험한 동글은 RTL8812BU(`0bda:b812`)예요.

## 빌드

macOS 14 이상, Xcode(SwiftUI 매크로 때문), Docker(VM 이미지를 처음 만들 때)가 필요해요.

```bash
./app/build_app.sh
```

```bash
./app/build_app.sh --install
```

VM 이미지까지 다시 만들려면:

```bash
GODSEON_REBUILD_VM=1 ./app/build_app.sh
```

결과물은 `dist/GodseonDongle.app`(약 58MB)이고, `--install`을 붙이면 `/Applications`에 복사해요.

새로 빌드한 앱은 ad-hoc 서명이 바뀌어서, 처음 저장된 Wi-Fi에 붙을 때 macOS가 키체인의 비밀번호를 이 앱에 줘도 되는지 한 번 물어요. **항상 허용**을 누르면 돼요.

## 처음 실행

1. 앱을 열고 **도우미 설치**를 눌러요. 관리자 암호는 macOS가 직접 물어요.
2. 동글을 꽂으면 도우미가 가져와 VM에 붙여요.
3. 목록에서 Wi-Fi를 고르고 비밀번호와 IP 설정을 넣은 뒤 **연결**을 눌러요.
4. 고정 IP 네트워크라면 **직접 입력**을 체크하고 IP·서브넷·게이트웨이와 추가 경로(예: `10.10.0.0/24 → 192.168.50.254`)를 넣어요. 체크를 풀면 자동(DHCP)으로 받고, 적어 둔 값은 남아 있어요.
5. 설정에서 **로그인할 때 열기**를 켜면 로그인할 때 저절로 떠요. 저장된 네트워크에는 자동으로 다시 붙어요.

- 목록 맨 위 **현재 상태**를 누르면 연결, 맥 경로, USB/IP 상태를 다시 볼 수 있어요.
- 비밀번호 칸의 눈 버튼을 누르면 친 글자가 보이고 입력기도 바꿀 수 있어요. 저장된 비밀번호는 Touch ID나 맥 암호로 확인한 뒤 볼 수 있어요.
- 설정의 **언어**에서 시스템 설정 따름, 한국어, English를 고를 수 있어요. 바로 바뀌어요.
- 앱을 업데이트한 뒤 설정에 **도우미 업데이트**가 보이면 눌러요(관리자 암호).

## 포트

이 프로젝트는 **9408**만 써요. 8080, 5000 같은 흔한 포트는 쓰지 않아요.

| 어디 | 무엇 |
|---|---|
| 맥 `0.0.0.0:9408` | 도우미의 USB/IP 서버. 앱이 띄운 VM 주소에서 오는 연결만 받아요 |
| VM `eth0:9408` | 제어 API. 맥 쪽 연결만 받고, 부팅마다 바뀌는 토큰이 필요해요 |

## 지금 상태 (2026-11-17)

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
  - 그래서 도우미가 rtw88 동글(RTL8812BU·8822BU·8811CU·8821CU·8812CU·8822CU)의 받기 응답을 보고, Trigger 프레임만 든 응답은 VM에 넘기지 않고 그 요청을 동글에 다시 걸어요. 설정의 **Wi-Fi 6 Trigger 프레임 거르기**로 끌 수 있어요.
  - 거르기를 켠 뒤에는 VM으로 가는 받기 요청이 초당 약 715개에서 약 50개로 줄었고(도우미가 초당 350~430개를 걸러요), CPU는 도우미 약 10% → 5%, VM 약 20% → 6%가 됐어요. 연결과 맥 경로는 그대로 돌아요.
- **알려진 점:** 동글이 한 번 이상한 상태가 돼 올리기가 1.6Mbit/s로 떨어졌어요. 다음에 다시 인식될 때는 USB Full Speed(12Mbit/s)로 잡혔고, 다시 꽂으니 풀렸어요. 지금은 느린 USB 모드면 앱이 경고해요.

## 폴더

| 폴더 | 내용 |
|---|---|
| `app/` | 맥 앱 (SwiftUI, Virtualization). `build_app.sh`로 번들을 만들어요. 아이콘은 `app/icon/make_icon.swift`로 그려요 |
| `app/Resources/*.lproj` | 영어 문자열. 코드의 한국어 문자열이 키예요. `python3 app/tools/check_strings.py`로 빠진 번역을 찾아요 |
| `helper/` | root 도우미 `godseon-dongled` (USB/IP 서버 + 맥 경로 + Trigger 프레임 거르기), 설치·제거 스크립트 |
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
