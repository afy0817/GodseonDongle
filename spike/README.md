# USB/IP 실험 (2026-11-17)

Apple 개발자 유료 계정 없이, macOS 기본 Virtualization VM에 USB Wi-Fi 동글을 넘길 수 있는지 확인한 실험이에요. 여기서 확인한 방식이 앱(`../app`, `../helper`)의 바탕이에요.

```
맥: usbipd (IOUSBHost로 동글을 직접 열기) ──TCP 9408──┐
                                                      │ VZ NAT (192.168.64.x 또는 65.x)
VM: vhci_hcd + usbip attach → rtw88 드라이버 → wlan0 ◀─┘ → Wi-Fi B
```

| 파일 | 내용 |
|---|---|
| `usbipd/usbipd.m` | 맥 쪽 USB/IP 서버 (Objective-C, IOUSBHost). 제어·벌크·인터럽트 전송, 요청 취소(unlink), 10초 통계 |
| `vzrun/vzrun.swift` | Virtualization.framework로 VM 띄우기. 콘솔 입력은 FIFO |
| `connect.sh` | VM API로 Wi-Fi 연결. 비밀번호는 맥에서 PSK로 바꿔서 보내요 |
| [GodseonDongle-VM](https://github.com/afy0817/GodseonDongle-VM) | VM 이미지 빌더(실험 당시 `../vm/`). ThruRNDIS-Wi-Fi에서 가져와 `vhci_hcd`, `linux-tools-usbip`, `usbip-attach`를 더했어요 |

## 1차: 동작 확인

- **권한 없이 동글 열기:** 다른 앱이 동글을 잡고 있지 않으면 root도 필요 없었어요. 잡고 있으면 root로 가져와야 해요(앱의 도우미가 이렇게 해요).
- **VM:** USB/IP로 장치를 인식했고, `rtw88_8822bu`가 펌웨어 30.20.0을 올려 `wlan0`이 생겼어요.
- **Wi-Fi:** 31개를 찾았고 국가 코드 KR이 적용됐어요. 시험용 망(WPA2, 5GHz 36번, 고정 IP)에 붙었어요.
- **맥 메모리:** VM 210MB + usbipd 7MB + vzrun 3MB, 합쳐서 약 220MB예요. UTM VM은 약 710MB였어요.

## 2차: 속도와 안정성

시험 조건은 이래요.

- **상대:** 그 망 안의 서버에 512MB 무작위 파일을 scp로 올리고 내려받았어요. 시험용 망은 인터넷이 없어서 이 서버를 썼어요.
- **지연:** 전송하는 동안 VM 안에서 ping을 0.2초마다 보냈어요.
- **기준:** 같은 시험을 지금 쓰는 UTM 방식에서도 했어요. UTM 방식은 QEMU USB 전달에 WireGuard 터널을 거쳐요.
- **Wi-Fi 연결 상태:** 신호 -37~-42dBm, 받기 270Mbit/s(VHT MCS7 40MHz 2×2), 보내기 81Mbit/s(MCS2)였어요.

| | UTM | USB/IP |
|---|---|---|
| 올리기 512MB | 324.8초, 13.2Mbit/s | 310.1초, 13.8Mbit/s |
| 내려받기 512MB | 382.2초, 11.2Mbit/s | 144.9초, 29.6Mbit/s |
| 올리는 중 ping 평균 / 최대 / 손실 | 554ms / 2.6초 / 3.7% | 146ms / 1.0초 / 0.3% |
| 내려받는 중 ping 평균 / 최대 | 81ms / 857ms | 41ms / 387ms |
| 쉴 때 ping 평균 | 29~38ms | 18~21ms |
| 파일 sha256 | 일치 | 일치 |

- **송신 멈춤:** 5분 넘게 계속 올리는 동안 한 번도 없었어요. 내려받는 동안 동글로 보내는 요청은 모두 1ms 안에 끝났어요.
- **올리기 속도:** 두 방식 모두 약 14Mbit/s에서 막히고 VM CPU는 남았어요. 그래서 USB/IP가 아니라 동글이 보내기 속도를 MCS2로 낮게 고르는 쪽 한계로 보여요.
- **CPU:** usbipd 3~6%, VM 7~19%예요. UTM의 QEMU는 24%였어요.
- **복구:** 시험 중에 usbipd를 껐다 켰더니 VM이 동글을 다시 붙이고 Wi-Fi까지 16초 만에 돌아왔어요. 열려 있던 SSH 연결도 끊기지 않았어요.

## 실험하며 고친 것

- **ioData 버퍼:** IOUSBHost의 `ioDataWithCapacity:` 버퍼는 길이를 바꾸면 예외가 나요. 받는 쪽은 일반 버퍼를 써요.
- **PSK:** VM API(`api.cgi`)는 비밀번호 원문이 아니라 64자리 PSK를 받아요(`thrurndis-wifi-config`의 `valid_psk`).
- **첫 검색:** VM 시작 직후 첫 Wi-Fi 검색은 비어 있을 수 있어요(UTM 때도 같았어요).
- **메모리 누수:** 소켓을 읽는 반복에서 만든 버퍼가 연결이 끊길 때까지 쌓였어요. 512MB를 올리자 usbipd가 800MB까지 불었어요. 요청마다 autorelease pool을 비우게 고쳐서 7MB로 유지돼요.
- **통계 타이머:** 통계 타이머를 지역 변수에만 담아서 ARC가 바로 해제했어요. 전역에 붙잡아 두게 고쳤어요.
- **VM이 갑자기 꺼질 때:** 서버가 끊긴 줄 모르고 기다렸어요. 도우미는 TCP keepalive로 약 11초 안에 알아채고, 새 연결이 오면 옛 연결을 정리해요.
- **`usbip-attach`의 맥 주소 찾기:** 기본 경로 첫 줄로 맥 주소를 찾았는데, Wi-Fi가 붙으면 wlan0 경로가 걸릴 수 있었어요. eth0(VZ NAT) 쪽 게이트웨이만 쓰게 바꿨어요.
- **"record connection" 오류:** `/var/run/vhci_hcd`가 없어서 붙이기는 성공하고도 실패로 보고했어요. 폴더를 미리 만들게 바꿨어요.
- **`usb-tx-watcher` 제외:** VZ USB 전달의 xHCI 링을 보는 스크립트라 USB/IP에서는 쓸모가 없어요. 이미지에서 뺐어요.

## 다시 해 보기

이 실험은 동글을 다른 VM(UTM 등)에서 뺀 뒤에 해요.

```bash
# 1) VM 이미지: GodseonDongle-VM 릴리스의 vm_assets.zip 을 dist/ 에 풀거나, 그 저장소에서 ./build.sh (Docker 필요)
ditto -x -k vm_assets.zip dist
# 2) 빌드
clang -fobjc-arc -O2 spike/usbipd/usbipd.m -o spike/usbipd/usbipd -framework Foundation -framework IOKit -framework IOUSBHost
swiftc -O spike/vzrun/vzrun.swift -o spike/vzrun/vzrun && codesign -s - -f --entitlements spike/vzrun/vzrun.entitlements spike/vzrun/vzrun
# 3) 실행 (GODSEON_USBIP_STATS: 통계 간격, 초)
GODSEON_USBIP_STATS=10 spike/usbipd/usbipd 0x0bda 0xb812 9408 &
spike/vzrun/vzrun dist/vm_assets/Image-lts dist/vm_assets/initramfs-thrurndis-wifi /tmp/gd.log /tmp/gd.fifo \
    godseon.usbip=gw/1-1 thrurndis-wifi.token=<토큰> thrurndis-wifi.country=KR &
spike/connect.sh <VM IP> <토큰>
```
