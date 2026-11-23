# 기여하기

*Everything in this repository is under the MIT License, and so are contributions to it. The VM image the app bundles is developed in [GodseonDongle-VM](https://github.com/afy0817/GodseonDongle-VM) (GPL-2.0-or-later).*

이슈나 풀 리퀘스트를 보낼 때 아래만 지켜 주세요. 이 저장소에 보내 주는 코드와 문서는 저장소와 같은 MIT 라이선스([LICENSE](LICENSE))로 받아요.

## 라이선스 표기

- 새 파일 맨 위에는 다른 파일처럼 SPDX 머리말을 넣어요. 주석을 넣을 수 없는 파일(이미지 등)은 [REUSE.toml](REUSE.toml)에 적어요.

  ```swift
  // SPDX-FileCopyrightText: 2026 <이름>
  // SPDX-License-Identifier: MIT
  ```

- 있는 파일을 크게 고쳤다면 `SPDX-FileCopyrightText` 줄에 자기 이름을 더해요. 원래 있던 줄은 지우지 않아요.
- 다른 곳에서 가져온 코드는 원래 저작권 줄과 라이선스를 그대로 두고 출처를 적어요. GPL처럼 조건이 더 붙는 라이선스의 코드는 이 저장소에 넣지 않아요.
- [REUSE](https://reuse.software) 도구가 있으면 `reuse lint`로 빠진 표기를 찾을 수 있어요.

## 어디를 고치나요

- VM 이미지(리눅스 커널, 드라이버 목록, 게스트 스크립트)는 [GodseonDongle-VM](https://github.com/afy0817/GodseonDongle-VM)에서 고쳐요. 이 저장소에서는 [vm-assets.env](vm-assets.env)로 어느 릴리스를 쓸지만 정해요.
- 앱 문자열을 바꾸면 `python3 app/tools/check_strings.py`로 빠진 영어 번역을 확인해요.
