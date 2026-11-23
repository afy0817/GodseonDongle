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
    /// Every USB device plugged into the Mac; `devices` keeps the ones the app can use.
    @Published private(set) var usbDevices: [USBDevice.Info] = []
    /// What the user chose for each device, by DeviceKey.
    @Published private(set) var deviceSettings: [String: DeviceSetting]
    @Published private(set) var savedNetworks: [CredentialStore.Entry] = []
    @Published private(set) var busy: String?
    /// Routes left out because they overlap a network the Mac itself is on.
    @Published private(set) var skippedRoutes: [String] = []
    @Published private(set) var notice: String?
    /// macOS is asking whether this build may read the saved Wi-Fi password (see autoConnect).
    @Published private(set) var waitingForKeychain = false
    @Published var lastError: String?

    /// The master switch: devices are taken and the VM runs only while this is on.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "Enabled")
            if !enabled { Task { await stopVM() } }
            syncHelper()
        }
    }
    /// A USB ID to treat as a Wi-Fi dongle although no driver in the VM lists it (Settings);
    /// before the device list it named the one dongle the app used.
    @Published var dongleID: String {
        didSet { UserDefaults.standard.set(dongleID, forKey: "DongleID"); syncHelper() }
    }
    @Published var country: String {
        didSet { UserDefaults.standard.set(country, forKey: "Country") }
    }
    @Published var extraRoutesText: String {
        didSet { UserDefaults.standard.set(extraRoutesText, forKey: "ExtraRoutes"); syncHelper() }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let defaultDongle = "0bda:b812"
    /// The phone's host link on the VM's bridge (helper/godseon-dongled.m, GodseonDongle-VM's
    /// initramfs/init-network).
    static let hostLink = "10.94.8.0/30"
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
    /// The guest's last answer on the phone's gateway, kept through a status call that fails, so
    /// one slow answer does not take the Mac's internet away.
    private var tetherReady = false
    private var usbWatcher: USBWatcher?
    /// The dongle routes the helper keeps, and when the guest last confirmed them (holdRoutes).
    private var heldRoutes: [String] = []
    private var routesConfirmedAt: Date?
    /// How long the routes outlive the guest's last confirmation: a status call that fails, or
    /// one answer saying "not ready" while a gateway check runs, used to take them away for
    /// 6 to 12 seconds.
    private static let routeHoldSeconds: TimeInterval = 30

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "Enabled") as? Bool ?? true
        dongleID = defaults.string(forKey: "DongleID") ?? ""
        country = defaults.string(forKey: "Country") ?? "KR"
        extraRoutesText = defaults.string(forKey: "ExtraRoutes") ?? ""
        if let saved = DeviceStore.load() {
            deviceSettings = saved
        } else {
            // An app from before the device list used one dongle: 0bda:b812 unless set otherwise.
            // A first install starts empty and takes the first dongle plugged in (noteDevices).
            var settings: [String: DeviceSetting] = [:]
            if FileManager.default.fileExists(atPath: Helper.configURL.path) {
                let id = (defaults.string(forKey: "DongleID") ?? Self.defaultDongle).lowercased()
                settings["wifi:\(id)"] = DeviceSetting(kind: .wifi, name: "", usbID: id, use: true, internet: false,
                                                       rxFilter: defaults.object(forKey: "RxFilter") as? Bool ?? true)
            }
            deviceSettings = settings
            DeviceStore.save(settings)
        }
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
        // A phone switching tethering on comes back as another USB device: look at once.
        usbWatcher = USBWatcher { [weak self] in self?.nextPoll = .distantPast }
    }

    /// Set by the window: a closed window polls far less often.
    var windowVisible = true {
        didSet { if windowVisible && !oldValue { nextPoll = .distantPast } }
    }
    private var nextPoll = Date.distantPast

    /// 2 s while things change (VM starting, dongle attaching, Wi-Fi joining, routes settling);
    /// once settled, 3 s with the window open and 15 s with only the menu bar icon.
    private var pollInterval: TimeInterval {
        switch tetherPhase {
        case .attaching, .switching: return 2
        default: break
        }
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

    /// The Wi-Fi side: the dongle and the network it joins.
    enum Phase: Equatable {
        case needsHelper, off, noWiFiDevice, noDongle, dongleError(String), startingVM, vmFailed(String)
        case attaching, chooseNetwork, connecting(String), problem(String, String), connected
    }

    var phase: Phase {
        if !helperInstalled { return .needsHelper }
        if !enabled { return .off }
        if case .failed(let message) = vmState { return .vmFailed(message) }
        guard activeWifi != nil else { return .noWiFiDevice }
        if let helper = helperStatus?.wifi {
            if helper.device == "absent" { return .noDongle }
            if helper.device == "error" { return .dongleError(helper.device_error) }
        }
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

    /// The phone side, for the phone chosen in the device list.
    enum TetherPhase: Equatable {
        /// No phone chosen (or the app is off).
        case none
        case unplugged, tetheringOff
        /// The installed helper predates phones.
        case helperUpdate
        case error(String)
        /// Going to the VM, or the VM is getting the phone's network ready.
        case attaching
        /// The VM has the phone's network; the Mac's internet does not go through it.
        case ready
        /// The Mac's internet is being moved to the phone (macOS has not put it first yet).
        case switching
        /// The Mac's internet goes through the phone.
        case internet
    }

    var tetherPhase: TetherPhase {
        guard helperInstalled, enabled, let phone = activePhone else { return .none }
        guard phone.plugged != nil else { return .unplugged }
        guard phone.tethering else { return .tetheringOff }
        guard let helper = helperStatus else { return .attaching }
        if helper.version < 2 { return .helperUpdate }
        if let slot = helper.tether, slot.device == "error" { return .error(slot.device_error) }
        guard vmState == .running, helper.tether?.client == true, tetherReady else { return .attaching }
        guard phone.internet else { return .ready }
        switch helper.internet?.state {
        case "primary": return .internet
        case "error": return .error(helper.internet?.error ?? "")
        default: return .switching
        }
    }

    // MARK: Devices

    /// The device list: what is plugged in that the app can use (dongles first), then devices
    /// set up earlier that are not plugged in.
    var devices: [DeviceItem] {
        var items: [DeviceItem] = []
        var listed = Set<String>()
        for info in usbDevices {
            guard let kind = kind(of: info) else { continue }
            let key = DeviceKey.of(info, kind: kind)
            guard listed.insert(key).inserted else { continue }
            items.append(DeviceItem(key: key, kind: kind, plugged: info, setting: deviceSettings[key],
                                    tethering: kind == .tether && isTethering(info)))
        }
        for (key, setting) in deviceSettings where !listed.contains(key) {
            items.append(DeviceItem(key: key, kind: setting.kind, plugged: nil, setting: setting, tethering: false))
        }
        return items.sorted {
            ($0.plugged == nil ? 1 : 0, $0.kind == .wifi ? 0 : 1, $0.key) < ($1.plugged == nil ? 1 : 0, $1.kind == .wifi ? 0 : 1, $1.key)
        }
    }

    /// The dongle and the phone chosen in the device list (at most one of each).
    var activeWifi: DeviceItem? { devices.first { $0.kind == .wifi && $0.use } }
    var activePhone: DeviceItem? { devices.first { $0.kind == .tether && $0.use } }
    var wifiSpeed: USBDevice.Speed? { activeWifi?.plugged?.speed }

    /// USB tethering is on: the registry shows the phone's RNDIS function, or the helper holds
    /// this very device as the phone. While captured, and while the guest reconfigures it, a
    /// device's interfaces can be missing from the registry; reading that as "tethering off"
    /// would make the app hand the phone back in the middle of its use.
    private func isTethering(_ info: USBDevice.Info) -> Bool {
        if info.hasRNDIS { return true }
        guard let slot = helperStatus?.tether, slot.device == "captured" else { return false }
        return slot.usb == info.usbID
    }

    /// What a plugged-in device is to the app; nil for one it has no use for.
    private func kind(of info: USBDevice.Info) -> USBDevice.Kind? {
        if info.hasRNDIS || info.isAndroid { return .tether }
        let extra = dongleID.trimmingCharacters(in: .whitespaces).lowercased()
        if USBDevice.wifiIDs.contains(info.usbID) || info.usbID == extra { return .wifi }
        if deviceSettings[DeviceKey.of(info, kind: .wifi)] != nil { return .wifi }        // set up by its ID earlier
        if deviceSettings[DeviceKey.of(info, kind: .tether)] != nil { return .tether }    // a phone in another USB mode
        return nil
    }

    /// Remembers the names of the devices set up, and takes the first dongle plugged in while
    /// no dongle is set up at all (a first install, or after the only one was forgotten). One
    /// the user turned off stays off.
    private func noteDevices() {
        var settings = deviceSettings
        for item in devices {
            guard let plugged = item.plugged else { continue }
            if var setting = settings[item.key] {
                guard setting.name != plugged.name || setting.usbID != plugged.usbID else { continue }
                setting.name = plugged.name
                setting.usbID = plugged.usbID
                settings[item.key] = setting
            } else if item.kind == .wifi, !settings.values.contains(where: { $0.kind == .wifi }) {
                settings[item.key] = DeviceSetting(kind: .wifi, name: plugged.name, usbID: plugged.usbID, use: true,
                                                   internet: false)
            }
        }
        if settings != deviceSettings {
            deviceSettings = settings
            DeviceStore.save(settings)
        }
    }

    /// Choosing a device to use stops the use of any other of the same kind.
    func setUse(_ key: String, _ on: Bool) {
        changeSetting(key) { setting, settings in
            setting.use = on
            guard on else { return }
            for (other, value) in settings where other != key && value.kind == setting.kind && value.use {
                settings[other]?.use = false
            }
        }
    }

    func setInternet(_ key: String, _ on: Bool) { changeSetting(key) { setting, _ in setting.internet = on } }
    func setRxFilter(_ key: String, _ on: Bool) { changeSetting(key) { setting, _ in setting.rxFilter = on } }
    func setTSOOff(_ key: String, _ on: Bool) { changeSetting(key) { setting, _ in setting.tsoOff = on } }

    /// Drops a device that is not plugged in from the list.
    func forgetDevice(_ key: String) {
        var settings = deviceSettings
        settings[key] = nil
        saveSettings(settings)
    }

    /// One save for the device's setting (created when it has none) and any others it changes.
    private func changeSetting(_ key: String, _ change: (inout DeviceSetting, inout [String: DeviceSetting]) -> Void) {
        guard let item = devices.first(where: { $0.key == key }) else { return }
        var settings = deviceSettings
        var setting = settings[key]
            ?? DeviceSetting(kind: item.kind, name: item.plugged?.name ?? "", usbID: item.usbID, use: false,
                             internet: item.kind == .tether)
        change(&setting, &settings)
        settings[key] = setting
        saveSettings(settings)
    }

    private func saveSettings(_ settings: [String: DeviceSetting]) {
        guard settings != deviceSettings else { return }
        deviceSettings = settings
        DeviceStore.save(settings)
        syncHelper()
        nextPoll = .distantPast
    }

    /// The device= lines for the helper: the dongle as 1-1, the phone as 1-2. A phone goes to
    /// the VM only in tethering mode; otherwise macOS keeps it (file transfer, adb).
    private var helperDevices: [Helper.DeviceLine] {
        var lines: [Helper.DeviceLine] = []
        if let wifi = activeWifi, !wifi.usbID.isEmpty {
            lines.append(Helper.DeviceLine(busid: Helper.wifiBusID, usbID: wifi.usbID, serial: nil, tether: false,
                                           rxFilter: wifi.rxFilter && wifi.filterApplies, tsoOff: wifi.tsoOff))
        }
        if let phone = activePhone, let plugged = phone.plugged, phone.tethering {
            lines.append(Helper.DeviceLine(busid: Helper.tetherBusID, usbID: plugged.usbID, serial: plugged.safeSerial,
                                           tether: true, rxFilter: false))
        }
        return lines
    }

    /// The Mac's internet goes through the phone once the guest's gateway for it is up.
    private var wantsInternet: Bool {
        guard let phone = activePhone, phone.internet, phone.tethering, vmState == .running else { return false }
        return tetherReady
    }

    /// Routes the helper keeps on the Mac (see holdRoutes).
    var desiredRoutes: [String] { heldRoutes }

    /// What the guest's latest answer asks for: the dongle network's own subnet, the extra routes
    /// saved for that network, and the user's own list; never one overlapping the Mac's own
    /// networks.
    private var confirmedRoutes: [String] {
        guard let status, status.isAssociated, status.route_ready else { return [] }
        var routes: [String] = []
        if let subnet = status.subnetCIDR { routes.append(subnet) }
        let saved = savedNetworks.first { $0.ssid == status.ssid }?.activeStaticIPv4?.routes ?? []
        for route in saved where !routes.contains(route.destination) { routes.append(route.destination) }
        for cidr in IPv4.parseCIDRList(extraRoutesText) ?? [] where !routes.contains(cidr) { routes.append(cidr) }
        let local = Self.macNetworks()
        return routes.filter { cidr in
            // The helper leaves out the phone's host link and what lies inside it (see its tick()).
            if let prefix = Int(cidr.split(separator: "/").last ?? ""), prefix >= 30,
               IPv4.overlaps(cidr, Self.hostLink) { return false }
            return !local.contains { IPv4.overlaps($0, cidr) }
        }
    }

    /// Keeps the last confirmed routes through a short gap in the guest's answers. They go at
    /// once when the VM is not running or the user disconnected, and otherwise once the guest has
    /// not confirmed them for routeHoldSeconds; a confirmed set replaces them right away.
    private func holdRoutes() {
        let confirmed = confirmedRoutes
        if !confirmed.isEmpty {
            heldRoutes = confirmed
            routesConfirmedAt = Date()
        } else if vm.state != .running || userDisconnected
                    || Date().timeIntervalSince(routesConfirmedAt ?? .distantPast) > Self.routeHoldSeconds {
            heldRoutes = []
            routesConfirmedAt = nil
        }
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
        update(\.usbDevices, USBDevice.all())
        noteDevices()
        if enabled && helperInstalled { ensureVM() }
        if let api {
            do {
                let fresh = try await api.status()
                update(\.status, fresh)
                tetherReady = fresh.tether_ready == true
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
            tetherReady = false
            update(\.status, nil)
            if !scanResults.isEmpty { scanResults = [] }
        }
        holdRoutes()
        let planned = plannedRoutes, desired = desiredRoutes
        update(\.skippedRoutes, status?.route_ready == true ? planned.filter { !desired.contains($0) } : [])
        syncHelper()
    }

    private func vmChanged() {
        update(\.vmState, vm.state)
        update(\.guestAddress, vm.address)
        if vm.state != .running {
            update(\.status, nil)
            tetherReady = false
            if !scanResults.isEmpty { scanResults = [] }
        }
        syncHelper()
    }

    private func syncHelper() {
        guard helperInstalled else { return }
        holdRoutes()
        let active = enabled && !quitting
        Helper.writeConfig(owner: active ? getpid() : nil, devices: active ? helperDevices : [],
                           guest: vm.address, routes: active ? desiredRoutes : [], internet: active && wantsInternet)
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
            text += "== app\n" + AppInfo.report
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

    /// Gives the devices back and removes the Mac routes and the phone's internet before the
    /// app goes away.
    func prepareForQuit() async {
        quitting = true
        syncHelper()
        await stopVM()
        Helper.writeConfig(owner: nil, devices: [], guest: nil, routes: [])
    }
}
