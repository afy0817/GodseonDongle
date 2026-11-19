// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

enum NetworkSelection: Hashable {
    /// The current state: connection, Mac routes, USB/IP (the first row of the list).
    case overview
    /// A row of the device list, by DeviceKey.
    case device(String)
    case network(String)
    case hidden
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var selection: NetworkSelection? = .overview
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader(model: model)
            Divider()
            if model.phase == .needsHelper {
                SetupView(model: model)
            } else {
                HStack(spacing: 0) {
                    NetworkList(model: model, selection: $selection)
                        .frame(width: 300)
                    Divider()
                    Group {
                        switch selection {
                        case .device(let key):
                            DeviceDetail(model: model, key: key, onDone: { self.selection = .overview })
                        case .network, .hidden:
                            NetworkDetail(model: model, selection: selection!, onDone: { self.selection = .overview })
                                .id(selection)
                        case .overview, nil:
                            OverviewPane(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            MessageBanner(model: model)
            Divider()
            FooterBar(model: model)
        }
        .frame(minWidth: 840, minHeight: 560)
        .toolbar { WindowToolbar(model: model, showingSettings: $showingSettings) }
        .onAppear { model.windowVisible = true }
        .onDisappear { model.windowVisible = false }
        .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
    }
}

// MARK: Header

/// What the window and the menu say about the current phase.
@MainActor
struct PhaseText {
    let model: AppModel

    var title: String {
        switch model.phase {
        case .needsHelper: return t("처음 설정이 필요해요")
        case .off: return t("꺼져 있어요")
        case .noWiFiDevice:
            return model.tetherPhase == .none ? t("쓸 장치를 고르세요") : TetherText(model: model).title
        case .noDongle: return t("동글을 꽂아 주세요")
        case .dongleError: return t("동글을 가져오지 못했어요")
        case .startingVM: return t("VM을 시작하는 중…")
        case .vmFailed: return t("VM이 멈췄어요")
        case .attaching: return t("동글을 VM에 붙이는 중…")
        case .chooseNetwork: return t("연결할 Wi-Fi를 고르세요")
        case .connecting(let ssid): return t("\(ssid)에 연결하는 중…")
        case .problem(let ssid, _): return t("\(ssid)에 연결하지 못했어요")
        case .connected: return t("\(model.status?.ssid ?? "")에 연결됨")
        }
    }

    var detail: String {
        switch model.phase {
        case .needsHelper: return t("동글과 폰을 VM에 넘기고 맥 경로를 잡는 도우미를 한 번 설치해요.")
        case .off: return t("켜면 동글과 폰을 가져와 VM을 시작해요.")
        case .noWiFiDevice:
            return model.tetherPhase == .none ? t("왼쪽 장치 목록에서 동글이나 USB 테더링 폰을 켜요.") : TetherText(model: model).detail
        case .noDongle: return t("USB Wi-Fi 동글(\(model.activeWifi?.usbID ?? ""))이 보이지 않아요.")
        case .dongleError(let message): return message
        case .startingVM: return t("작은 리눅스 VM이 동글을 맡아요.")
        case .vmFailed(let message): return message
        case .attaching: return t("USB/IP로 동글을 넘기고 있어요.")
        case .chooseNetwork: return t("왼쪽 목록에서 네트워크를 고르면 돼요.")
        case .connecting: return t("Wi-Fi에 붙고 주소를 받는 중이에요.")
        case .problem(_, let message): return message
        case .connected:
            guard let status = model.status else { return "" }
            var parts = ["\(status.ipv4)/\(status.prefix ?? 0)"]
            if !status.gateway.isEmpty { parts.append(t("게이트웨이 \(status.gateway)")) }
            if let freq = status.freq { parts.append(Band.label(freq)) }
            if let rssi = status.rssi { parts.append(t("신호 \(rssi) dBm")) }
            if let speed = model.wifiSpeed, speed.isSlow { parts.append(t("⚠︎ 동글이 느린 USB 모드예요")) }
            return parts.joined(separator: " · ")
        }
    }

    var color: Color {
        switch model.phase {
        case .connected: return .green
        case .noWiFiDevice where model.tetherPhase != .none: return TetherText(model: model).color
        case .off, .needsHelper, .noWiFiDevice: return .secondary
        case .problem, .vmFailed, .dongleError, .noDongle: return .orange
        default: return .accentColor
        }
    }

    var symbol: String {
        switch model.phase {
        case .connected: return "antenna.radiowaves.left.and.right"
        case .noWiFiDevice where model.tetherPhase != .none: return "iphone"
        case .noWiFiDevice: return "cable.connector"
        case .off: return "power"
        case .needsHelper: return "lock.shield"
        case .noDongle: return "cable.connector"
        case .problem, .vmFailed, .dongleError: return "exclamationmark.triangle.fill"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    var busy: Bool {
        switch model.phase {
        case .startingVM, .attaching, .connecting: return true
        case .noWiFiDevice: return TetherText(model: model).busy
        default: return false
        }
    }
}

/// What the window and the menu say about the phone (TetherPhase).
@MainActor
struct TetherText {
    let model: AppModel

    private var name: String { model.activePhone?.name ?? t("폰") }

    // Names are product names in any language, so no Korean particle follows one.
    var title: String {
        switch model.tetherPhase {
        case .none: return ""
        case .unplugged: return t("폰을 꽂아 주세요")
        case .tetheringOff: return t("폰에서 USB 테더링을 켜 주세요")
        case .helperUpdate: return t("도우미를 업데이트해 주세요")
        case .error: return t("폰을 쓰지 못했어요")
        case .attaching: return t("폰을 VM에 붙이는 중…")
        case .ready: return t("\(name) 테더링 연결됨")
        case .switching: return t("맥 인터넷을 폰으로 바꾸는 중…")
        case .internet: return t("맥 인터넷: \(name)")
        }
    }

    var detail: String {
        switch model.tetherPhase {
        case .none: return ""
        case .unplugged: return t("USB 테더링에 쓸 폰: \(name)")
        case .tetheringOff: return t("\(name) · 갤럭시는 설정 > 연결 > 모바일 핫스팟 및 테더링에 있어요.")
        case .helperUpdate: return t("설치된 도우미가 폰을 다루지 못하는 예전 버전이에요. 설정에서 업데이트해요.")
        case .error(let message): return message
        case .attaching: return t("USB/IP로 넘기고 폰에서 주소를 받는 중이에요.")
        case .ready, .switching, .internet:
            guard let status = model.status, let ip = status.tether_ipv4, !ip.isEmpty else { return "" }
            var parts = ["\(ip)/\(status.tether_prefix ?? 0)"]
            if let gateway = status.tether_gateway, !gateway.isEmpty { parts.append(t("게이트웨이 \(gateway)")) }
            if model.tetherPhase == .ready { parts.append(t("맥 인터넷은 그대로예요")) }
            return parts.joined(separator: " · ")
        }
    }

    var color: Color {
        switch model.tetherPhase {
        case .internet, .ready: return .green
        case .error, .helperUpdate, .unplugged, .tetheringOff: return .orange
        default: return .accentColor
        }
    }

    var busy: Bool { model.tetherPhase == .attaching || model.tetherPhase == .switching }
}

struct StatusHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let text = PhaseText(model: model)
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(text.color.opacity(0.15))
                Image(systemName: text.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(text.color)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(text.title).font(.title3.weight(.semibold))
                    if text.busy || model.busy != nil { ProgressView().controlSize(.small) }
                }
                Text(model.busy ?? text.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // The phone gets its own line while the title is about Wi-Fi.
                if model.phase != .noWiFiDevice, model.tetherPhase != .none {
                    let tether = TetherText(model: model)
                    Label(tether.title, systemImage: "iphone")
                        .font(.callout)
                        .foregroundStyle(tether.color)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: Toolbar

/// The window's controls, top right: the master switch, the less frequent actions, Settings.
/// The header and the footer only show state.
struct WindowToolbar: ToolbarContent {
    @ObservedObject var model: AppModel
    @Binding var showingSettings: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.phase != .needsHelper {
                Toggle(t("동글·폰 사용"), isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .help(t("끄면 동글과 폰을 macOS에 돌려주고 VM을 멈춰요."))
            }
            Menu {
                Button(t("VM 다시 시작")) { Task { await model.restartVM() } }
                    .disabled(!model.helperInstalled || !model.enabled)
                Divider()
                Button(t("VM 진단 정보")) { Task { await model.saveDiagnostics() } }
                    .disabled(model.vmState != .running)
                Button(t("VM 콘솔 로그")) { NSWorkspace.shared.open(GuestVM.consoleLogURL) }
                Button(t("도우미 로그")) { NSWorkspace.shared.open(URL(fileURLWithPath: Helper.logPath)) }
                    .disabled(!FileManager.default.fileExists(atPath: Helper.logPath))
            } label: {
                Label(t("더 보기"), systemImage: "ellipsis.circle")
            }
            .help(t("더 보기"))
            Button {
                showingSettings = true
            } label: {
                Label(t("설정"), systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help(t("설정"))
        }
    }
}

// MARK: First run

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text(t("도우미를 한 번 설치해요"))
                .font(.title2.weight(.semibold))
            Text(t("동글과 폰을 VM에 넘기고, 맥에서 그쪽 네트워크로 가는 경로를 잡으려면 관리자 권한이 필요해요. 설치할 때 macOS가 관리자 암호를 물어요."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button {
                Task { await model.installHelper() }
            } label: {
                Text(t("도우미 설치")).frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy != nil)
            Text(t("설치 위치: \(Helper.installedBinary)"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: Messages and footer

struct MessageBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.waitingForKeychain {
            banner(t("macOS가 저장된 Wi-Fi 비밀번호를 이 앱에 줘도 되는지 묻고 있어요. 키체인 창에서 ‘항상 허용’을 눌러 주세요. 앱을 업데이트하면 한 번 물어요."),
                   symbol: "key.fill", color: .orange, closable: false)
        } else if let message = model.lastError ?? model.notice {
            banner(message, symbol: model.lastError != nil ? "exclamationmark.circle.fill" : "info.circle.fill",
                   color: model.lastError != nil ? .orange : .accentColor, closable: true)
        }
    }

    private func banner(_ message: String, symbol: String, color: Color, closable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            if closable {
                Button {
                    model.lastError = nil
                    model.clearNotice()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(t("닫기"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }
}

struct FooterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            FooterItem(symbol: "cable.connector", text: dongleText)
            if let phoneText {
                FooterItem(symbol: "iphone", text: phoneText)
            }
            FooterItem(symbol: "cpu", text: vmText)
            if let devices = model.helperStatus?.devices.filter(\.client), !devices.isEmpty {
                FooterItem(symbol: "arrow.up.arrow.down",
                           text: String(format: "↓ %.1f  ↑ %.1f Mbit/s", devices.map(\.in_mbps).reduce(0, +),
                                        devices.map(\.out_mbps).reduce(0, +)))
            }
            if let routes = routeText {
                FooterItem(symbol: "point.3.connected.trianglepath.dotted", text: routes)
            }
            Spacer()
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var dongleText: String {
        guard model.helperInstalled else { return t("도우미 없음") }
        guard let helperStatus = model.helperStatus else { return t("도우미 응답 없음") }
        guard model.activeWifi != nil, let helper = helperStatus.wifi else { return t("동글 · 쉬는 중") }
        let speed = model.wifiSpeed.map { " · \($0.label)\($0.isSlow ? t(" (느림)") : "")" } ?? ""
        switch helper.device {
        case "captured": return (helper.client ? t("동글 \(helper.usb) · VM에 붙음") : t("동글 \(helper.usb) · 가져옴")) + speed
        case "absent": return t("동글 \(helper.usb) · 꽂혀 있지 않음")
        case "error": return t("동글 \(helper.usb) · 오류")
        default: return t("동글 · 쉬는 중")
        }
    }

    private var phoneText: String? {
        switch model.tetherPhase {
        case .none: return nil
        case .unplugged: return t("폰 · 꽂혀 있지 않음")
        case .tetheringOff: return t("폰 · 테더링 꺼짐")
        case .helperUpdate, .error: return t("폰 · 오류")
        case .attaching: return t("폰 · 붙이는 중")
        case .ready: return t("폰 · VM에 붙음")
        case .switching: return t("폰 · 인터넷으로 바꾸는 중")
        case .internet: return t("폰 · 맥 인터넷")
        }
    }

    private var vmText: String {
        switch model.vmState {
        case .stopped: return t("VM 꺼짐")
        case .starting: return t("VM 시작 중")
        case .stopping: return t("VM 끄는 중")
        case .failed: return t("VM 멈춤")
        case .running: return "VM \(model.guestAddress ?? t("주소 받는 중"))"
        }
    }

    private var routeText: String? {
        guard let routes = model.helperStatus?.routes, !routes.isEmpty else { return nil }
        let conflicts = routes.filter { $0.state != "ok" }.count
        return conflicts == 0 ? t("맥 경로 \(routes.count)개") : t("맥 경로 \(routes.count - conflicts)개 · 충돌 \(conflicts)개")
    }
}

struct FooterItem: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

enum Band {
    static func label(_ freq: Int) -> String {
        switch freq {
        case 2400..<2500: return t("2.4 GHz · 채널 \(freq == 2484 ? 14 : (freq - 2407) / 5)")
        case 5000..<5925: return t("5 GHz · 채널 \((freq - 5000) / 5)")
        case 5925..<7125: return t("6 GHz · 채널 \((freq - 5950) / 5)")
        default: return "\(freq) MHz"
        }
    }

    static func short(_ freq: Int) -> String {
        switch freq {
        case 2400..<2500: return "2.4 GHz"
        case 5000..<5925: return "5 GHz"
        case 5925..<7125: return "6 GHz"
        default: return ""
        }
    }

    /// 0...1 for the Wi-Fi symbol's variable value.
    static func level(_ rssi: Int) -> Double {
        switch rssi {
        case (-60)...: return 1
        case (-70)...: return 0.66
        case (-80)...: return 0.33
        default: return 0.05
        }
    }
}
