// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import SwiftUI

enum NetworkSelection: Hashable {
    /// The current state: connection, Mac routes, USB/IP (the first row of the list).
    case overview
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
                        if let selection, selection != .overview {
                            NetworkDetail(model: model, selection: selection, onDone: { self.selection = .overview })
                                .id(selection)
                        } else {
                            OverviewPane(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            MessageBanner(model: model)
            Divider()
            FooterBar(model: model, showingSettings: $showingSettings)
        }
        .frame(minWidth: 840, minHeight: 560)
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
        case .needsHelper: return t("동글을 VM에 넘기고 맥 경로를 잡는 도우미를 한 번 설치해요.")
        case .off: return t("켜면 동글을 가져와 VM을 시작해요.")
        case .noDongle: return t("USB Wi-Fi 동글(\(model.dongleID))이 보이지 않아요.")
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
            if let speed = model.dongleSpeed, speed.isSlow { parts.append(t("⚠︎ 동글이 느린 USB 모드예요")) }
            return parts.joined(separator: " · ")
        }
    }

    var color: Color {
        switch model.phase {
        case .connected: return .green
        case .off, .needsHelper: return .secondary
        case .problem, .vmFailed, .dongleError, .noDongle: return .orange
        default: return .accentColor
        }
    }

    var symbol: String {
        switch model.phase {
        case .connected: return "antenna.radiowaves.left.and.right"
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
        default: return false
        }
    }
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
            }
            Spacer()
            if model.isConnected {
                Button(t("연결 끊기")) { Task { await model.disconnect() } }
                    .disabled(model.busy != nil)
            }
            if model.phase != .needsHelper {
                Toggle(t("동글 사용"), isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .help(t("끄면 동글을 macOS에 돌려주고 VM을 멈춰요."))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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
            Text(t("동글을 VM에 넘기고, 맥에서 동글 쪽 네트워크로 가는 경로를 잡으려면 관리자 권한이 필요해요. 설치할 때 macOS가 관리자 암호를 물어요."))
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
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 18) {
            FooterItem(symbol: "cable.connector", text: dongleText)
            FooterItem(symbol: "cpu", text: vmText)
            if let helper = model.helperStatus, helper.client {
                FooterItem(symbol: "arrow.up.arrow.down",
                           text: String(format: "↓ %.1f  ↑ %.1f Mbit/s", helper.in_mbps, helper.out_mbps))
            }
            if let routes = routeText {
                FooterItem(symbol: "point.3.connected.trianglepath.dotted", text: routes)
            }
            Spacer()
            if model.helperInstalled {
                Button(t("VM 다시 시작")) { Task { await model.restartVM() } }
                    .disabled(!model.enabled)
            }
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help(t("설정"))
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var dongleText: String {
        guard model.helperInstalled else { return t("도우미 없음") }
        guard let helper = model.helperStatus else { return t("도우미 응답 없음") }
        let speed = model.dongleSpeed.map { " · \($0.label)\($0.isSlow ? t(" (느림)") : "")" } ?? ""
        switch helper.device {
        case "captured": return (helper.client ? t("동글 \(helper.usb) · VM에 붙음") : t("동글 \(helper.usb) · 가져옴")) + speed
        case "absent": return t("동글 \(helper.usb) · 꽂혀 있지 않음")
        case "error": return t("동글 \(helper.usb) · 오류")
        default: return t("동글 · 쉬는 중")
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
