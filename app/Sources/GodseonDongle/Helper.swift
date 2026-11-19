// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation

/// The root helper (helper/godseon-dongled), installed once with an administrator prompt.
/// The app tells it what to do through a config file and reads back a JSON status file.
enum Helper {
    static let label = "io.github.afy0817.godseon-dongled"
    static let installedBinary = "/usr/local/libexec/godseon-dongled"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let statusPath = "/var/run/godseon-dongled.status"
    static let logPath = "/var/log/godseon-dongled.log"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GodseonDongle/helper.conf")
    }

    private static var bundledDirectory: URL? { Bundle.main.url(forResource: "helper", withExtension: nil) }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath) && FileManager.default.fileExists(atPath: installedBinary)
    }

    /// The installed daemon differs from the one in this build.
    static var isOutdated: Bool {
        guard isInstalled, let bundled = bundledDirectory?.appendingPathComponent("godseon-dongled") else { return false }
        return FileManager.default.contentsEqual(atPath: bundled.path, andPath: installedBinary) == false
    }

    /// USB/IP bus IDs: the VM attaches both (GuestVM's kernel command line).
    static let wifiBusID = "1-1"
    static let tetherBusID = "1-2"

    struct Status: Decodable, Equatable {
        /// 2 since the helper serves several devices and the phone's internet; 1 before.
        var version: Int
        var pid: Int32
        var active: Bool
        var guest: String
        var guest_interface: String
        var routes: [Route]
        var devices: [Device]
        /// The phone's internet; nil from a helper before version 2.
        var internet: Internet?

        var wifi: Device? { devices.first { $0.busid == Helper.wifiBusID } }
        var tether: Device? { devices.first { $0.busid == Helper.tetherBusID } }

        struct Route: Decodable, Equatable, Hashable {
            var cidr: String
            /// "ok" or "conflict" (that prefix already goes elsewhere)
            var state: String
            var gateway: String
            var interface: String
        }

        /// One USB/IP bus ID. A helper before version 2 has only the dongle, at the top level.
        struct Device: Decodable, Equatable {
            var busid: String
            /// "wifi" or "tether"
            var kind: String
            var usb: String
            /// "idle", "absent" (not plugged in), "captured", "error"
            var device: String
            var device_error: String
            /// The VM has the device attached over USB/IP.
            var client: Bool
            var client_seconds: Int
            var imports: Int
            var in_mbps: Double
            var out_mbps: Double
            var max_out_ms: Double
            var oldest_out_ms: Double
            var errors: Int
            var stalls: Int
            var resets: Int
            /// URBs per second over the last poll window, by kind (0 from helpers that predate them).
            var urbs_per_s: Double
            var control_per_s: Double
            var in_per_s: Double
            var out_per_s: Double
            /// Bulk IN completions that held only Wi-Fi 6 Trigger frames and went straight back to the dongle.
            var filtered_per_s: Double

            private enum CodingKeys: String, CodingKey {
                case busid, kind, usb, device, device_error, client, client_seconds, imports
                case in_mbps, out_mbps, max_out_ms, oldest_out_ms, errors, stalls, resets
                case urbs_per_s, control_per_s, in_per_s, out_per_s, filtered_per_s
            }

            // Lenient: the first helper build wrote some flags as 0/1, and a field it lacks
            // must not hide the whole status.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                func flag(_ key: CodingKeys) -> Bool {
                    if let value = try? c.decode(Bool.self, forKey: key) { return value }
                    return ((try? c.decode(Int.self, forKey: key)) ?? 0) != 0
                }
                func number(_ key: CodingKeys) -> Double { (try? c.decode(Double.self, forKey: key)) ?? 0 }
                func text(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
                busid = (try? c.decode(String.self, forKey: .busid)) ?? Helper.wifiBusID
                kind = (try? c.decode(String.self, forKey: .kind)) ?? "wifi"
                usb = text(.usb)
                device = text(.device)
                device_error = text(.device_error)
                client = flag(.client)
                client_seconds = Int(number(.client_seconds))
                imports = Int(number(.imports))
                in_mbps = number(.in_mbps)
                out_mbps = number(.out_mbps)
                max_out_ms = number(.max_out_ms)
                oldest_out_ms = number(.oldest_out_ms)
                errors = Int(number(.errors))
                stalls = Int(number(.stalls))
                resets = Int(number(.resets))
                urbs_per_s = number(.urbs_per_s)
                control_per_s = number(.control_per_s)
                in_per_s = number(.in_per_s)
                out_per_s = number(.out_per_s)
                filtered_per_s = number(.filtered_per_s)
            }
        }

        struct Internet: Decodable, Equatable {
            var wanted: Bool
            /// "off", "published" (macOS has not put it first yet), "primary", "error"
            var state: String
            var error: String
        }

        private enum CodingKeys: String, CodingKey {
            case version, pid, active, guest, guest_interface, routes, devices, internet, usb
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func flag(_ key: CodingKeys) -> Bool {
                if let value = try? c.decode(Bool.self, forKey: key) { return value }
                return ((try? c.decode(Int.self, forKey: key)) ?? 0) != 0
            }
            version = (try? c.decode(Int.self, forKey: .version)) ?? 1
            pid = try c.decode(Int32.self, forKey: .pid)
            active = flag(.active)
            guest = (try? c.decode(String.self, forKey: .guest)) ?? ""
            guest_interface = (try? c.decode(String.self, forKey: .guest_interface)) ?? ""
            routes = (try? c.decode([Route].self, forKey: .routes)) ?? []
            internet = try? c.decode(Internet.self, forKey: .internet)
            if let devices = try? c.decode([Device].self, forKey: .devices) {
                self.devices = devices
            } else if ((try? c.decode(String.self, forKey: .usb)) ?? "").isEmpty {
                devices = []
            } else {
                devices = [try Device(from: decoder)]          // version 1: the dongle at the top level
            }
        }
    }

    /// One device= line: what to hand to the VM under a bus ID.
    struct DeviceLine: Equatable {
        var busid: String
        var usbID: String
        /// Only the device with this USB serial number (a phone).
        var serial: String?
        var tether: Bool
        /// The dongle is one of USBDevice.rtw88IDs and its Trigger frame filter is on.
        var rxFilter: Bool
        /// A dongle: the helper turns TSO off Mac-wide while the VM has it.
        var tsoOff = false
    }

    /// nil while the daemon is not running.
    static func status() -> Status? {
        guard let data = FileManager.default.contents(atPath: statusPath),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        // A root process answers kill(0) with EPERM: it exists.
        guard kill(status.pid, 0) == 0 || errno == EPERM else { return nil }
        return status
    }

    /// owner nil: the helper releases every device and removes its routes and the phone's
    /// network service. internet: the Mac's internet through the tether device.
    static func writeConfig(owner: Int32?, devices: [DeviceLine], guest: String?, routes: [String],
                            internet: Bool = false) {
        var lines = ["# Written by GodseonDongle; read by \(label)."]
        if let owner { lines.append("owner=\(owner)") }
        for device in devices {
            var line = "device=\(device.busid) \(device.usbID)"
            if let serial = device.serial { line += " serial=\(serial)" }
            if device.tether { line += " kind=tether" }
            if device.rxFilter { line += " rx_filter=rtw88" }
            if device.tsoOff { line += " tso=off" }
            lines.append(line)
        }
        // A helper before version 2 reads only these: the dongle.
        if let wifi = devices.first(where: { $0.busid == wifiBusID }) {
            lines.append("usb=\(wifi.usbID)")
            if wifi.rxFilter { lines.append("rx_filter=rtw88") }
        }
        if let guest { lines.append("guest=\(guest)") }
        lines += routes.map { "route=\($0)" }
        if internet { lines.append("internet=1") }
        let text = lines.joined(separator: "\n") + "\n"
        let url = configURL
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func install() async throws {
        guard let directory = bundledDirectory else { throw HelperError.missingBundle }
        // Only a first install needs the file; rewriting it on an update would make the
        // running helper drop the devices and the routes for a moment.
        if !FileManager.default.fileExists(atPath: configURL.path) {
            writeConfig(owner: nil, devices: [], guest: nil, routes: [])
        }
        try await runAsAdministrator([
            "/bin/sh", directory.appendingPathComponent("install.sh").path,
            directory.appendingPathComponent("godseon-dongled").path, configURL.path,
        ])
    }

    static func uninstall() async throws {
        guard let directory = bundledDirectory else { throw HelperError.missingBundle }
        try await runAsAdministrator(["/bin/sh", directory.appendingPathComponent("uninstall.sh").path])
    }

    /// macOS asks for the administrator password itself; the app never sees it.
    private static func runAsAdministrator(_ arguments: [String]) async throws {
        func quoted(_ value: String) -> String {
            "quoted form of \"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = arguments.map(quoted).joined(separator: " & \" \" & ")
        let script = "do shell script \(command) with administrator privileges"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: HelperError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum HelperError: LocalizedError {
        case missingBundle
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missingBundle: return t("앱 안에 도우미 파일이 없어요. 앱을 다시 빌드해 주세요.")
            case .failed(let message):
                return message.contains("-128") ? t("취소했어요.") : t("도우미 작업이 실패했어요: \(message)")
            }
        }
    }
}
