// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var vmState: GuestVM.State = .stopped
    @Published private(set) var guestAddress: String?
    @Published private(set) var status: GuestAPI.Status?
    @Published private(set) var scanResults: [GuestAPI.ScanResult] = []
    @Published private(set) var scanning = false
    @Published private(set) var helperInstalled = Helper.isInstalled
    @Published private(set) var helperOutdated = false
    @Published private(set) var helperStatus: Helper.Status?
    /// The dongle's negotiated USB speed, nil while it is not plugged in.
    @Published private(set) var dongleSpeed: USBDevice.Speed?
    @Published private(set) var savedNetworks: [CredentialStore.Entry] = []
    @Published private(set) var busy: String?
    /// Routes left out because they overlap a network the Mac itself is on.
    @Published private(set) var skippedRoutes: [String] = []
    @Published private(set) var notice: String?
    /// macOS is asking whether this build may read the saved Wi-Fi password (see autoConnect).
    @Published private(set) var waitingForKeychain = false
    @Published var lastError: String?

    /// The master switch: the dongle is taken and the VM runs only while this is on.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "Enabled")
            if !enabled { Task { await stopVM() } }
            syncHelper()
        }
    }
    @Published var dongleID: String {
        didSet { UserDefaults.standard.set(dongleID, forKey: "DongleID"); syncHelper() }
    }
    @Published var country: String {
        didSet { UserDefaults.standard.set(country, forKey: "Country") }
    }
    @Published var extraRoutesText: String {
        didSet { UserDefaults.standard.set(extraRoutesText, forKey: "ExtraRoutes"); syncHelper() }
    }
    /// Keep Wi-Fi 6 Trigger frames away from the VM (rtw88 dongles only; see USBDevice.rtw88IDs).
    @Published var rxFilter: Bool {
        didSet { UserDefaults.standard.set(rxFilter, forKey: "RxFilter"); syncHelper() }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let defaultDongle = "0bda:b812"
    private let vm = GuestVM()
    /// New for every boot: the guest takes it from the kernel command line.
    private var token = AppModel.newToken()
    private var userDisconnected = false
    private var autoConnectBoot: String?
    private var scannedBoot: String?
    private var deviceWasPresent = false
    private var vmStarts: [Date] = []
    private var lastHelperCheck = Date.distantPast
    private var quitting = false

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "Enabled") as? Bool ?? true
        dongleID = defaults.string(forKey: "DongleID") ?? Self.defaultDongle
        country = defaults.string(forKey: "Country") ?? "KR"
        extraRoutesText = defaults.string(forKey: "ExtraRoutes") ?? ""
        rxFilter = defaults.object(forKey: "RxFilter") as? Bool ?? true
        savedNetworks = CredentialStore.entries()
        vm.onChange = { [weak self] in self?.vmChanged() }
        Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                self.nextPoll = Date().addingTimeInterval(self.pollInterval)
                // Wakes every second only to see whether a poll is due (cheap); the guest's
                // status API starts a couple of dozen processes, so it is asked only when due.
                while Date() < self.nextPoll, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Set by the window: a closed window polls far less often.
    var windowVisible = true {
        didSet { if windowVisible && !oldValue { nextPoll = .distantPast } }
    }
    private var nextPoll = Date.distantPast

    /// 2 s while things change (VM starting, dongle attaching, Wi-Fi joining, routes settling);
    /// once settled, 3 s with the window open and 15 s with only the menu bar icon.
    private var pollInterval: TimeInterval {
        switch phase {
        case .startingVM, .attaching, .connecting: return 2
        case .connected where helperStatus?.routes.count != desiredRoutes.count: return 2
        default: return windowVisible ? 3 : 15
        }
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Hex.encode(Data(bytes))
    }

    private var api: GuestAPI? {
        guard vm.state == .running, let host = vm.address else { return nil }
        return GuestAPI(host: host, token: token)
    }

    /// Assigns only a changed value: every assignment redraws the window.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: State for the views

    enum Phase: Equatable {
        case needsHelper, off, noDongle, dongleError(String), startingVM, vmFailed(String)
        case attaching, chooseNetwork, connecting(String), problem(String, String), connected
    }

    var phase: Phase {
        if !helperInstalled { return .needsHelper }
        if !enabled { return .off }
        if let helper = helperStatus {
            if helper.device == "absent" { return .noDongle }
            if helper.device == "error" { return .dongleError(helper.device_error) }
        }
        if case .failed(let message) = vmState { return .vmFailed(message) }
        guard vmState == .running, let status else { return .startingVM }
        guard status.device else { return .attaching }
        if status.isAssociated && !status.ipv4.isEmpty { return .connected }
        let configured = status.configuredSSID
        if configured.isEmpty { return .chooseNetwork }
        switch status.auth_error {
        case "wrong-key": return .problem(configured, t("비밀번호가 맞지 않아요."))
        case "auth-failed": return .problem(configured, t("인증에 실패했어요."))
        case "not-found": return .problem(configured, t("이 네트워크가 보이지 않아요."))
        default: break
        }
        if status.hasIPConflict { return .problem(configured, t("같은 IP를 쓰는 다른 기기가 있어요.")) }
        return .connecting(configured)
    }

    var isConnected: Bool { phase == .connected }

    /// Routes the helper keeps on the Mac: the dongle network's own subnet, the extra routes saved
    /// for that network, and the user's own list; never one overlapping the Mac's own networks.
    var desiredRoutes: [String] {
        guard let status, status.isAssociated, status.route_ready else { return [] }
        var routes: [String] = []
        if let subnet = status.subnetCIDR { routes.append(subnet) }
        let saved = savedNetworks.first { $0.ssid == status.ssid }?.activeStaticIPv4?.routes ?? []
        for route in saved where !routes.contains(route.destination) { routes.append(route.destination) }
        for cidr in IPv4.parseCIDRList(extraRoutesText) ?? [] where !routes.contains(cidr) { routes.append(cidr) }
        let local = Self.macNetworks()
        return routes.filter { cidr in !local.contains { IPv4.overlaps($0, cidr) } }
    }

    private var plannedRoutes: [String] {
        guard let status, status.isAssociated else { return [] }
        var routes: [String] = []
        if let subnet = status.subnetCIDR { routes.append(subnet) }
        for route in savedNetworks.first(where: { $0.ssid == status.ssid })?.activeStaticIPv4?.routes ?? []
        where !routes.contains(route.destination) { routes.append(route.destination) }
        for cidr in IPv4.parseCIDRList(extraRoutesText) ?? [] where !routes.contains(cidr) { routes.append(cidr) }
        return routes
    }

    /// IPv4 networks the Mac is directly on, other than the VMs' bridges and tunnels.
    static func macNetworks() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let name = String(cString: entry.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("bridge") || name.hasPrefix("utun") || name.hasPrefix("vmenet") { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let prefix = mask.nonzeroBitCount
            guard prefix > 0, prefix < 32 else { continue }
            let cidr = "\(IPv4.format(ip & mask))/\(prefix)"
            if !result.contains(cidr) { result.append(cidr) }
        }
        return result
    }

    // MARK: Polling

    func refresh() async {
        if quitting { return }
        if Date().timeIntervalSince(lastHelperCheck) > 10 {
            lastHelperCheck = Date()
            update(\.helperInstalled, Helper.isInstalled)
            update(\.helperOutdated, Helper.isOutdated)
            update(\.launchAtLogin, SMAppService.mainApp.status == .enabled)
        }
        update(\.helperStatus, Helper.status())
        update(\.dongleSpeed, USBDevice.speed(of: dongleID))
        if enabled && helperInstalled { ensureVM() }
        if let api {
            do {
                let fresh = try await api.status()
                update(\.status, fresh)
                await autoConnectIfNeeded(fresh)
                // Show nearby networks without a click: once per boot, and again when the
                // dongle comes back (re-plugged, re-attached).
                let returned = fresh.device && !deviceWasPresent
                deviceWasPresent = fresh.device
                if fresh.device, scanResults.isEmpty, let boot = fresh.boot_id, boot != scannedBoot || returned {
                    scannedBoot = boot
                    await scan()
                }
            } catch {
                update(\.status, nil)
                deviceWasPresent = false
            }
        } else {
            deviceWasPresent = false
            update(\.status, nil)
            if !scanResults.isEmpty { scanResults = [] }
        }
        let planned = plannedRoutes, desired = desiredRoutes
        update(\.skippedRoutes, status?.route_ready == true ? planned.filter { !desired.contains($0) } : [])
        syncHelper()
    }

    private func vmChanged() {
        update(\.vmState, vm.state)
        update(\.guestAddress, vm.address)
        if vm.state != .running {
            update(\.status, nil)
            if !scanResults.isEmpty { scanResults = [] }
        }
        syncHelper()
    }

    private func syncHelper() {
        guard helperInstalled else { return }
        Helper.writeConfig(owner: (enabled && !quitting) ? getpid() : nil, usb: dongleID,
                           guest: vm.address, routes: quitting ? [] : desiredRoutes,
                           rxFilter: rxFilter && USBDevice.rtw88IDs.contains(dongleID))
    }

    /// Boots the guest while the app is on; a guest that keeps dying is left stopped.
    private func ensureVM() {
        switch vm.state {
        case .stopped, .failed: break
        default: return
        }
        let now = Date()
        vmStarts = vmStarts.filter { now.timeIntervalSince($0) < 10 * 60 }
        if vmStarts.count >= 4 {
            update(\.notice, t("VM이 10분 사이에 네 번 멈췄어요. 아래 ‘VM 다시 시작’을 눌러 주세요."))
            return
        }
        if let last = vmStarts.last, now.timeIntervalSince(last) < 5 { return }
        vmStarts.append(now)
        token = Self.newToken()
        do {
            try vm.start(token: token, country: country)
        } catch {
            update(\.notice, error.localizedDescription)
        }
    }

    /// A fresh guest has no network; hand it the most recently used saved one, once per boot.
    private func autoConnectIfNeeded(_ status: GuestAPI.Status) async {
        guard let boot = status.boot_id, boot != autoConnectBoot, status.device else { return }
        autoConnectBoot = boot
        guard status.configured_ssid_hex.isEmpty, !userDisconnected, let entry = savedNetworks.first else { return }
        Task { await autoConnect(entry.ssid) }
    }

    /// The keychain read runs off the main thread: an ad-hoc signed build is a new app to the
    /// keychain, so the first read after an update waits for macOS to ask whether it may have
    /// the password, and the window and the status polling must go on meanwhile.
    private func autoConnect(_ ssid: String) async {
        let read = Task.detached(priority: .userInitiated) { CredentialStore.credential(for: ssid) }
        let hint = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { self?.update(\.waitingForKeychain, true) }
        }
        let credential = await read.value
        hint.cancel()
        update(\.waitingForKeychain, false)
        guard let credential, !userDisconnected else { return }
        do {
            try await api?.connect(credential)
        } catch {
            lastError = t("\(ssid)에 자동으로 연결하지 못했어요: \(error.localizedDescription)")
        }
    }

    // MARK: Actions

    private func perform(_ label: String, _ work: () async throws -> Void) async {
        busy = label
        lastError = nil
        do {
            try await work()
        } catch {
            lastError = error.localizedDescription
        }
        busy = nil
        await refresh()
    }

    func scan() async {
        guard let api, !scanning else { return }
        scanning = true
        lastError = nil
        do {
            var results = try await api.scan(trigger: true)
            // Right after the dongle joins a network or comes back, the guest can answer a scan
            // with nothing (wpa_supplicant busy); asking again a moment later finds the networks.
            if results.isEmpty {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                results = try await api.scan(trigger: true)
            }
            scanResults = Self.strongestPerSSID(results)
        } catch {
            lastError = error.localizedDescription
        }
        scanning = false
    }

    static func strongestPerSSID(_ results: [GuestAPI.ScanResult]) -> [GuestAPI.ScanResult] {
        var best: [String: GuestAPI.ScanResult] = [:]
        for result in results where !result.ssid.isEmpty {
            if let current = best[result.ssid], current.signal >= result.signal { continue }
            best[result.ssid] = result
        }
        return best.values.sorted { $0.signal > $1.signal }
    }

    func connect(_ credential: WiFiCredential) async {
        await perform(t("\(credential.ssid)에 연결하는 중…")) {
            try credential.validate()
            guard let api else { throw GuestAPI.APIError.server("no-wifi-device") }
            try await api.connect(credential)
            CredentialStore.save(credential)
            savedNetworks = CredentialStore.entries()
            userDisconnected = false
        }
    }

    /// Saves without connecting.
    func save(_ credential: WiFiCredential) {
        do {
            try credential.validate()
            CredentialStore.save(credential)
            savedNetworks = CredentialStore.entries()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func credential(for ssid: String) -> WiFiCredential? { CredentialStore.credential(for: ssid) }
    func hasSavedPassword(_ ssid: String) -> Bool { CredentialStore.hasPassword(for: ssid) }

    func disconnect() async {
        await perform(t("연결을 끊는 중…")) {
            try await api?.disconnect()
            userDisconnected = true
        }
    }

    func forget(_ ssid: String) async {
        if status?.configuredSSID == ssid { await disconnect() }
        CredentialStore.remove(ssid)
        savedNetworks = CredentialStore.entries()
    }

    func installHelper() async {
        await perform(t("도우미를 설치하는 중…")) {
            try await Helper.install()
            lastHelperCheck = .distantPast
        }
        update(\.helperInstalled, Helper.isInstalled)
        update(\.helperOutdated, Helper.isOutdated)
    }

    func uninstallHelper() async {
        enabled = false
        await perform(t("도우미를 지우는 중…")) {
            try await Helper.uninstall()
        }
        update(\.helperInstalled, Helper.isInstalled)
    }

    func restartVM() async {
        notice = nil
        vmStarts = []
        await stopVM()
        if enabled { ensureVM() }
    }

    private func stopVM() async {
        await vm.stop()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = t("로그인 항목을 바꾸지 못했어요: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func clearNotice() { notice = nil }

    static var diagnosticsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GodseonDongle/diag.txt")
    }

    /// Writes the guest's diagnostics plus the helper's status to ~/Library/Logs/GodseonDongle/diag.txt.
    func saveDiagnostics(open: Bool = true) async {
        guard let api else {
            lastError = t("VM이 켜져 있어야 진단 정보를 받을 수 있어요.")
            return
        }
        do {
            let report = try await api.diagnostics()
            var text = t("GodseonDongle 진단 정보 \(Date().formatted(date: .numeric, time: .standard))\n")
            if let data = FileManager.default.contents(atPath: Helper.statusPath) {
                text += "== helper status\n" + String(decoding: data, as: UTF8.self) + "\n"
            }
            text += report
            let url = Self.diagnosticsURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if open { NSWorkspace.shared.open(url) }
        } catch {
            lastError = t("진단 정보를 받지 못했어요: \(error.localizedDescription)")
        }
    }

    /// Gives the dongle back and removes the Mac routes before the app goes away.
    func prepareForQuit() async {
        quitting = true
        syncHelper()
        await stopVM()
        Helper.writeConfig(owner: nil, usb: dongleID, guest: nil, routes: [])
    }
}
