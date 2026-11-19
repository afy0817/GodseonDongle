// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import SwiftUI

/// What the list and the detail pane say about one device.
@MainActor
struct DeviceText {
    let model: AppModel
    let item: DeviceItem

    var state: String {
        guard item.plugged != nil else { return item.use ? t("꽂혀 있지 않음") : t("꽂혀 있지 않음 · 쓰지 않음") }
        switch item.kind {
        case .wifi:
            guard item.use else { return t("쓰지 않음") }
            guard model.enabled else { return t("꺼져 있음") }
            guard let helper = model.helperStatus?.wifi else { return t("사용 중") }
            if helper.device == "error" { return t("가져오지 못함") }
            guard helper.client else { return t("사용 중 · VM에 붙이는 중") }
            if model.isConnected, let ssid = model.status?.ssid { return t("사용 중 · \(ssid)에 연결됨") }
            return t("사용 중 · VM에 붙음")
        case .tether:
            guard item.tethering else { return item.use ? t("사용 중 · USB 테더링 꺼짐") : t("USB 테더링 꺼짐") }
            guard item.use else { return t("USB 테더링 켜짐 · 쓰지 않음") }
            switch model.tetherPhase {
            case .internet: return t("사용 중 · 맥 인터넷")
            case .switching: return t("사용 중 · 맥 인터넷으로 바꾸는 중")
            case .ready: return t("사용 중 · VM에 붙음")
            case .attaching: return t("사용 중 · VM에 붙이는 중")
            case .helperUpdate: return t("도우미 업데이트 필요")
            case .error: return t("오류")
            default: return model.enabled ? t("사용 중") : t("꺼져 있음")
            }
        }
    }

    var highlighted: Bool {
        guard item.use, item.plugged != nil, model.enabled else { return false }
        switch item.kind {
        case .wifi: return model.helperStatus?.wifi?.client == true
        case .tether: return model.tetherPhase == .ready || model.tetherPhase == .internet
        }
    }
}

struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let item: DeviceItem

    var body: some View {
        let text = DeviceText(model: model, item: item)
        HStack(spacing: 10) {
            Image(systemName: item.kind == .wifi ? "antenna.radiowaves.left.and.right" : "iphone")
                .foregroundStyle(item.plugged == nil ? .tertiary : .primary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(text.state)
                    .font(.caption)
                    .foregroundStyle(text.highlighted ? .green : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.use {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(text.highlighted ? .green : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DeviceDetail: View {
    @ObservedObject var model: AppModel
    let key: String
    let onDone: () -> Void

    var body: some View {
        if let item = model.devices.first(where: { $0.key == key }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.title2.weight(.semibold))
                        Text(subtitle(item)).font(.callout).foregroundStyle(.secondary)
                    }
                    switch item.kind {
                    case .wifi: wifi(item)
                    case .tether: phone(item)
                    }
                    if item.plugged == nil {
                        HStack {
                            Spacer()
                            Button(t("목록에서 지우기"), role: .destructive) {
                                model.forgetDevice(item.key)
                                onDone()
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 580, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(t("이 장치는 목록에서 빠졌어요."))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func subtitle(_ item: DeviceItem) -> String {
        var parts = [item.kind == .wifi ? t("USB Wi-Fi 동글") : t("안드로이드 폰 · USB 테더링")]
        if !item.usbID.isEmpty { parts.append(item.usbID) }
        if let speed = item.plugged?.speed { parts.append(speed.label) }
        parts.append(DeviceText(model: model, item: item).state)
        return parts.joined(separator: " · ")
    }

    private func use(_ item: DeviceItem) -> Binding<Bool> {
        Binding(get: { item.use }, set: { model.setUse(item.key, $0) })
    }

    @ViewBuilder
    private func wifi(_ item: DeviceItem) -> some View {
        FormBlock(t("사용")) {
            Toggle(t("이 동글로 Wi-Fi에 붙기"), isOn: use(item))
            Text(t("동글은 한 번에 하나만 써요. 켜면 다른 동글은 꺼져요."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        FormBlock(t("Wi-Fi 6 Trigger 프레임 거르기")) {
            Toggle(t("거르기"), isOn: Binding(get: { item.rxFilter }, set: { model.setRxFilter(item.key, $0) }))
                .disabled(!item.filterApplies)
            Text(item.filterApplies
                 ? t("주변 Wi-Fi 6 공유기가 보내는 Trigger 프레임은 이 동글이 쓰지 못하는데도 USB로 계속 올라와요. 도우미가 VM에 넘기지 않고 걸러서 CPU를 덜 써요.")
                 : t("Realtek RTL8812BU·8822BU·8811CU·8821CU·8812CU·8822CU 동글(Linux rtw88 드라이버)에만 쓸 수 있어요."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        FormBlock(t("큰 업로드 안정화")) {
            Toggle(t("TSO 끄기"), isOn: Binding(get: { item.tsoOff }, set: { model.setTSOOff(item.key, $0) }))
            Text(t("맥이 TCP 데이터를 64 KB 덩어리로 VM에 넘기지 않게 해요. 동글로 큰 파일을 올릴 때 속도가 출렁이거나 멈추는 일이 줄어요. 맥 전체 설정이라 동글을 쓰는 동안만 끄고, 끝나면 되돌려요. 폰을 맥 인터넷으로 쓸 때는 이 설정과 상관없이 꺼요."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if item.use, let speed = item.plugged?.speed, speed.isSlow {
            Label(t("동글이 느린 USB 모드(\(speed.label), 12Mbit/s)로 붙어 있어요. 동글을 뽑았다가 다시 꽂아 주세요."),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        if item.use, let helper = model.helperStatus?.wifi, helper.client {
            FormBlock("USB/IP") { USBIPGrid(device: helper) }
        }
    }

    @ViewBuilder
    private func phone(_ item: DeviceItem) -> some View {
        if item.use, model.tetherPhase == .helperUpdate {
            FormBlock(t("도우미")) {
                Text(t("설치된 도우미가 폰을 다루지 못하는 예전 버전이에요."))
                    .foregroundStyle(.orange)
                Button(t("도우미 업데이트")) { Task { await model.installHelper() } }
                    .disabled(model.busy != nil)
            }
        }
        if item.use, case .error(let message) = model.tetherPhase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        FormBlock(t("사용")) {
            Toggle(t("USB 테더링을 켜면 VM에 넘기기"), isOn: use(item))
            Text(t("폰에서 USB 테더링을 켤 때마다 VM이 받아 써요. 넘긴 동안에는 맥에서 이 폰으로 파일을 옮기거나 adb를 쓸 수 없어요. 폰은 한 번에 하나만 써요."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        FormBlock(t("맥 인터넷")) {
            Toggle(t("맥 인터넷을 이 폰으로"), isOn: Binding(get: { item.internet }, set: { model.setInternet(item.key, $0) }))
                .disabled(!item.use)
            Text(t("켜면 맥의 기본 경로와 DNS가 이 폰으로 가요. 내장 Wi-Fi는 연결된 채로 남아 그 대역에는 그대로 닿고, 동글 쪽 대역도 그대로 동글로 가요. 끄면 폰은 VM에만 붙어요."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if item.plugged != nil, !item.tethering {
            Label(t("폰에서 USB 테더링을 켜 주세요. 갤럭시는 설정 > 연결 > 모바일 핫스팟 및 테더링 > USB 테더링이에요."),
                  systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        if item.use, item.tethering, let status = model.status, status.tether == true {
            FormBlock(t("폰 네트워크")) { PhoneNetworkGrid(status: status) }
        }
        if item.use, let helper = model.helperStatus?.tether, helper.client {
            FormBlock("USB/IP") { USBIPGrid(device: helper) }
        }
    }
}

/// The phone's network as the VM got it.
struct PhoneNetworkGrid: View {
    let status: GuestAPI.Status

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            if let ip = status.tether_ipv4, !ip.isEmpty {
                InfoRow(label: t("주소"), value: "\(ip)/\(status.tether_prefix ?? 0)")
            } else {
                InfoRow(label: t("주소"), value: t("받는 중"))
            }
            if let gateway = status.tether_gateway, !gateway.isEmpty { InfoRow(label: t("게이트웨이"), value: gateway) }
            if let dns = status.tether_dns, !dns.isEmpty { InfoRow(label: "DNS", value: dns) }
            InfoRow(label: t("VM 게이트웨이"), value: status.tether_ready == true ? t("준비됨") : t("준비하는 중"))
        }
    }
}

/// The phone in the overview pane.
struct TetherBlock: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let text = TetherText(model: model)
        FormBlock(t("폰")) {
            Label(text.title, systemImage: "iphone")
                .foregroundStyle(text.color)
            if case .error(let message) = model.tetherPhase {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            } else if [.unplugged, .tetheringOff, .helperUpdate, .attaching].contains(model.tetherPhase) {
                Text(text.detail).foregroundStyle(.secondary)
            }
            if model.activePhone?.tethering == true, let status = model.status, status.tether == true {
                PhoneNetworkGrid(status: status)
            }
        }
    }
}
