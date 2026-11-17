// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import LocalAuthentication
import SwiftUI

// MARK: List

struct NetworkList: View {
    @ObservedObject var model: AppModel
    @Binding var selection: NetworkSelection?

    private var nearby: [GuestAPI.ScanResult] {
        model.scanResults.filter { result in !model.savedNetworks.contains { $0.ssid == result.ssid } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t("Wi-Fi 네트워크")).font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(t("주변 네트워크 다시 찾기"))
                .disabled(model.status?.device != true || model.scanning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            List(selection: $selection) {
                Section {
                    Label(t("현재 상태"), systemImage: "gauge.with.dots.needle.67percent")
                        .tag(NetworkSelection.overview)
                }
                if !model.savedNetworks.isEmpty {
                    Section(t("저장된 네트워크")) {
                        ForEach(model.savedNetworks) { entry in
                            let seen = model.scanResults.first { $0.ssid == entry.ssid }
                            NetworkRow(name: entry.ssid, subtitle: savedSubtitle(entry, seen: seen),
                                       secured: seen?.isSecured ?? model.hasSavedPassword(entry.ssid),
                                       signal: seen?.signal, current: isCurrent(entry.ssid))
                                .tag(NetworkSelection.network(entry.ssid))
                        }
                    }
                }
                Section(t("주변 네트워크")) {
                    if nearby.isEmpty {
                        Text(emptyText).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(nearby) { result in
                        NetworkRow(name: result.ssid, subtitle: Band.short(result.freq), secured: result.isSecured,
                                   signal: result.signal, current: isCurrent(result.ssid))
                            .tag(NetworkSelection.network(result.ssid))
                    }
                }
                Section {
                    Label(t("숨은 네트워크에 연결…"), systemImage: "plus.circle")
                        .tag(NetworkSelection.hidden)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func isCurrent(_ ssid: String) -> Bool {
        model.isConnected && model.status?.configuredSSID == ssid
    }

    private func savedSubtitle(_ entry: CredentialStore.Entry, seen: GuestAPI.ScanResult?) -> String {
        var parts: [String] = []
        if isCurrent(entry.ssid) {
            parts.append(t("연결됨"))
        } else if model.status?.configuredSSID == entry.ssid {
            parts.append(t("연결하는 중"))
        } else if let seen {
            parts.append(Band.short(seen.freq))
        } else if !model.scanResults.isEmpty {
            parts.append(t("보이지 않음"))
        }
        if entry.activeStaticIPv4 != nil { parts.append(t("고정 IP")) }
        return parts.joined(separator: " · ")
    }

    private var emptyText: String {
        if model.status?.device != true { return t("동글이 VM에 붙으면 보여요.") }
        return model.scanning ? t("찾는 중…") : t("새로 고침을 눌러 찾아보세요.")
    }
}

struct NetworkRow: View {
    let name: String
    let subtitle: String
    let secured: Bool
    let signal: Int?
    let current: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi", variableValue: signal.map(Band.level) ?? 0)
                .foregroundStyle(signal == nil ? .tertiary : .primary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(current ? .green : .secondary)
                }
            }
            Spacer(minLength: 4)
            if secured {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if current {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Detail

@MainActor
final class NetworkForm: ObservableObject {
    @Published var ssid: String
    @Published var password = ""
    @Published var hidden: Bool
    @Published var useStatic: Bool
    @Published var address: String
    @Published var subnet: String
    @Published var gateway: String
    @Published var dns: String
    @Published var routes: [RouteRow]

    struct RouteRow: Identifiable, Equatable {
        let id = UUID()
        var destination = ""
        var gateway = ""
    }

    init(ssid: String, hidden: Bool, saved: CredentialStore.Entry?) {
        self.ssid = ssid
        self.hidden = hidden
        let staticIPv4 = saved?.staticIPv4
        useStatic = staticIPv4 != nil && (saved?.useStatic ?? true)
        address = staticIPv4?.address ?? ""
        subnet = staticIPv4.map { "\($0.prefix)" } ?? "24"
        gateway = staticIPv4?.gateway ?? ""
        dns = staticIPv4?.dns.joined(separator: ", ") ?? ""
        routes = staticIPv4?.routes.map { RouteRow(destination: $0.destination, gateway: $0.gateway) } ?? []
    }

    /// An empty password field keeps the saved one. With 직접 입력 off the manual values are
    /// kept (when they parse) but not applied.
    func credential(saved: WiFiCredential?) throws -> WiFiCredential {
        func parse() throws -> StaticIPv4 {
            try StaticIPv4(addressText: address, subnetText: subnet, gatewayText: gateway, dnsText: dns,
                           routeRows: routes.map { (destination: $0.destination, gateway: $0.gateway) })
        }
        let staticIPv4 = useStatic ? try parse() : try? parse()
        return WiFiCredential(ssid: ssid, password: password.isEmpty ? (saved?.password ?? "") : password,
                              hidden: hidden, staticIPv4: staticIPv4, useStatic: useStatic && staticIPv4 != nil)
    }

    /// What the Mac would route to this network, as far as the fields tell.
    var plannedMacRoutes: String {
        guard useStatic else { return t("연결한 뒤 받은 주소의 대역") }
        var parts: [String] = []
        let pieces = address.split(separator: "/")
        let prefix = pieces.count == 2 ? IPv4.prefix(fromSubnet: String(pieces[1])) : IPv4.prefix(fromSubnet: subnet.isEmpty ? "24" : subnet)
        if let first = pieces.first, let ip = IPv4.parse(first), let prefix {
            parts.append("\(IPv4.format(ip & IPv4.mask(prefix)))/\(prefix)")
        }
        for row in routes {
            if let cidr = IPv4.canonicalCIDR(row.destination), !parts.contains(cidr) { parts.append(cidr) }
        }
        return parts.isEmpty ? t("IP 주소를 적으면 보여요") : parts.joined(separator: ", ")
    }
}

struct NetworkDetail: View {
    @ObservedObject var model: AppModel
    let selection: NetworkSelection
    let onDone: () -> Void
    @StateObject private var form: NetworkForm

    init(model: AppModel, selection: NetworkSelection, onDone: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.selection = selection
        self.onDone = onDone
        let ssid: String
        switch selection {
        case .network(let name): ssid = name
        case .hidden, .overview: ssid = ""
        }
        let saved = model.savedNetworks.first { $0.ssid == ssid }
        _form = StateObject(wrappedValue: NetworkForm(ssid: ssid, hidden: saved?.hidden ?? (selection == .hidden), saved: saved))
    }

    private var saved: CredentialStore.Entry? { model.savedNetworks.first { $0.ssid == form.ssid } }
    private var seen: GuestAPI.ScanResult? { model.scanResults.first { $0.ssid == form.ssid } }
    private var isConfigured: Bool { !form.ssid.isEmpty && model.status?.configuredSSID == form.ssid }
    private var isConnected: Bool { isConfigured && model.isConnected }
    private var canConnect: Bool { !form.ssid.isEmpty && model.status?.device == true && model.busy == nil }
    private var hasSavedPassword: Bool { saved != nil && model.hasSavedPassword(form.ssid) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection == .hidden ? t("숨은 네트워크") : form.ssid)
                        .font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }

                if selection == .hidden {
                    FormBlock(t("네트워크 이름")) {
                        TextField("SSID", text: $form.ssid).textFieldStyle(.roundedBorder)
                    }
                }

                FormBlock(t("비밀번호")) {
                    PasswordField(text: $form.password, placeholder: passwordPlaceholder,
                                  savedPassword: hasSavedPassword ? { model.credential(for: form.ssid)?.password } : nil,
                                  onSubmit: connect)
                    Text(t("눈 모양을 누르면 비밀번호가 보이고 입력기도 바꿀 수 있어요. 비밀번호는 이 맥의 키체인에 저장되고, VM에는 비밀번호 대신 여기서 계산한 키(PSK)만 넘겨요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                FormBlock(t("IP 주소")) {
                    Toggle(isOn: $form.useStatic) {
                        Text(t("직접 입력"))
                    }
                    .toggleStyle(.checkbox)
                    Text(form.useStatic ? t("아래 값으로 주소를 정해요.") : t("자동(DHCP)으로 받아요. 적어 둔 값은 지우지 않고 남겨 둬요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        fieldRow(t("IP 주소"), prompt: "192.168.0.20", text: $form.address)
                        fieldRow(t("서브넷"), prompt: t("255.255.255.0 또는 24"), text: $form.subnet)
                        fieldRow(t("게이트웨이"), prompt: t("없으면 비워 두세요"), text: $form.gateway)
                        fieldRow("DNS", prompt: t("쉼표로 구분, 비워 둬도 돼요"), text: $form.dns)
                    }
                    .disabled(!form.useStatic)
                }

                Group {
                    FormBlock(t("추가 경로")) {
                        Text(t("이 네트워크 안의 다른 라우터 뒤에 있는 대역이에요. 직접 입력일 때 써요."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach($form.routes) { $row in
                            HStack(spacing: 8) {
                                TextField(t("대역 (10.10.0.0/24)"), text: $row.destination)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                TextField(t("게이트웨이"), text: $row.gateway)
                                Button {
                                    form.routes.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(t("이 경로 지우기"))
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            form.routes.append(NetworkForm.RouteRow())
                        } label: {
                            Label(t("경로 추가"), systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(form.routes.count >= 8)
                    }
                }
                .disabled(!form.useStatic)

                FormBlock(t("맥에서 이 Wi-Fi로 보낼 대역")) {
                    Text(form.plannedMacRoutes).font(.callout).textSelection(.enabled)
                    Text(t("맥의 다른 네트워크(내장 Wi-Fi 등)와 겹치는 대역은 빼요. 다른 대역은 설정에서 더할 수 있어요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if saved != nil {
                        Button(t("삭제"), role: .destructive) {
                            Task {
                                await model.forget(form.ssid)
                                onDone()
                            }
                        }
                    }
                    Spacer()
                    if saved != nil {
                        Button(t("저장")) { save() }
                    }
                    if isConnected {
                        Button(t("연결 끊기")) { Task { await model.disconnect() } }
                    }
                    Button(isConfigured ? t("다시 연결") : t("연결"), action: connect)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canConnect)
                }
            }
            .padding(24)
            .frame(maxWidth: 580, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if isConnected {
            parts.append(t("연결됨"))
        } else if isConfigured {
            parts.append(t("연결하는 중"))
        } else if saved != nil {
            parts.append(t("저장됨"))
        }
        if let seen {
            parts.append(seen.isSecured ? t("보안") : t("열린 네트워크"))
            parts.append(Band.label(seen.freq))
            parts.append(t("신호 \(seen.signal) dBm"))
        } else if selection != .hidden && !isConnected && !model.scanResults.isEmpty {
            parts.append(t("지금 보이지 않음"))
        }
        return parts.joined(separator: " · ")
    }

    private var passwordPlaceholder: String {
        if !form.ssid.isEmpty, model.hasSavedPassword(form.ssid) { return t("저장된 비밀번호 사용 (바꾸려면 입력)") }
        if let seen, !seen.isSecured { return t("비밀번호 없음") }
        return t("비밀번호")
    }

    private func fieldRow(_ label: String, prompt: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        }
    }

    private func connect() {
        guard canConnect else { return }
        do {
            let credential = try form.credential(saved: model.credential(for: form.ssid))
            Task { await model.connect(credential) }
            form.password = ""
        } catch {
            model.lastError = error.localizedDescription
        }
    }

    private func save() {
        do {
            model.save(try form.credential(saved: model.credential(for: form.ssid)))
            form.password = ""
        } catch {
            model.lastError = error.localizedDescription
        }
    }
}

struct FormBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

/// A password field that can show what was typed (a plain field also lets the user switch input
/// methods, which a secure field blocks) and reveal the saved password after the user proves
/// it is them, the way macOS's own Wi-Fi settings do.
struct PasswordField: View {
    @Binding var text: String
    let placeholder: String
    /// Reads the saved password; nil when nothing is saved.
    let savedPassword: (() -> String?)?
    let onSubmit: () -> Void
    @State private var revealed = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if revealed {
                        TextField(placeholder, text: $text)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSubmit)
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(revealed ? t("비밀번호 가리기") : t("비밀번호 보기"))
            }
            if let savedPassword, text.isEmpty {
                Button(t("저장된 비밀번호 보기")) {
                    Task { await showSaved(savedPassword) }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func showSaved(_ read: () -> String?) async {
        problem = nil
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                   localizedReason: t("저장된 Wi-Fi 비밀번호를 보여 줘요")) else { return }
        } catch {
            if (error as? LAError)?.code != .userCancel { problem = t("본인 확인을 하지 못했어요: \(error.localizedDescription)") }
            return
        }
        guard let password = read(), !password.isEmpty else {
            problem = t("저장된 비밀번호가 없어요.")
            return
        }
        text = password
        revealed = true
    }
}

// MARK: Overview (nothing selected)

struct OverviewPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let status = model.status, model.isConnected {
                    FormBlock(t("지금 연결")) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            infoRow(t("네트워크"), status.ssid)
                            infoRow(t("주소"), "\(status.ipv4)/\(status.prefix ?? 0)" + (status.isStatic ? t(" (직접 입력)") : " (DHCP)"))
                            if !status.gateway.isEmpty { infoRow(t("게이트웨이"), status.gateway) }
                            if !status.dns.isEmpty { infoRow("DNS", status.dns) }
                            if let freq = status.freq { infoRow(t("대역"), Band.label(freq)) }
                            if let rssi = status.rssi { infoRow(t("신호"), "\(rssi) dBm") }
                            infoRow("AP", status.bssid)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(PhaseText(model: model).title).font(.title3.weight(.semibold))
                        Text(PhaseText(model: model).detail).foregroundStyle(.secondary)
                    }
                }

                if let speed = model.dongleSpeed, speed.isSlow {
                    Label(t("동글이 느린 USB 모드(\(speed.label), 12Mbit/s)로 붙어 있어요. 동글을 뽑았다가 다시 꽂아 주세요."),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                FormBlock(t("맥 경로")) {
                    let routes = model.helperStatus?.routes ?? []
                    if routes.isEmpty && model.skippedRoutes.isEmpty {
                        Text(model.isConnected ? t("보낼 대역이 없어요.") : t("Wi-Fi에 연결되면 그 대역을 이쪽으로 보내요."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(routes, id: \.self) { route in
                        HStack(spacing: 8) {
                            Image(systemName: route.state == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(route.state == "ok" ? .green : .orange)
                            Text(route.cidr).monospacedDigit()
                            Text(route.state == "ok" ? t("→ 동글")
                                 : t("다른 연결(\(route.interface.isEmpty ? route.gateway : route.interface))이 이미 쓰고 있어요"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.skippedRoutes, id: \.self) { cidr in
                        HStack(spacing: 8) {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            Text(cidr).monospacedDigit()
                            Text(t("맥의 다른 네트워크와 겹쳐서 뺐어요")).foregroundStyle(.secondary)
                        }
                    }
                }

                if let helper = model.helperStatus, helper.client {
                    FormBlock("USB/IP") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            infoRow(t("속도"), String(format: t("받기 %.1f · 보내기 %.1f Mbit/s"), helper.in_mbps, helper.out_mbps))
                            infoRow(t("붙어 있던 시간"), Self.duration(helper.client_seconds))
                            infoRow(t("송신 멈춤"), helper.stalls == 0 ? t("없음") : t("\(helper.stalls)번 (동글 재설정 \(helper.resets)번)"))
                            if helper.urbs_per_s > 0 {
                                infoRow(t("USB 요청"), String(format: t("초당 %.0f개 (제어 %.0f · 받기 %.0f · 보내기 %.0f)"),
                                                         helper.urbs_per_s, helper.control_per_s, helper.in_per_s, helper.out_per_s))
                            }
                            if helper.filtered_per_s > 0 {
                                infoRow(t("걸러낸 프레임"), String(format: t("초당 %.0f개 (Wi-Fi 6 Trigger)"), helper.filtered_per_s))
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return t("\(seconds)초") }
        if seconds < 3600 { return t("\(seconds / 60)분") }
        return t("\(seconds / 3600)시간 \((seconds % 3600) / 60)분")
    }
}
