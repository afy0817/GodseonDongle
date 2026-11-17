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

    struct Status: Decodable, Equatable {
        var pid: Int32
        var active: Bool
        var usb: String
        /// "idle", "absent" (not plugged in), "captured", "error"
        var device: String
        var device_error: String
        var guest: String
        var guest_interface: String
        /// The VM has the dongle attached over USB/IP.
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
        var routes: [Route]
        /// URBs per second over the last poll window, by kind (0 from helpers that predate them).
        var urbs_per_s: Double
        var control_per_s: Double
        var in_per_s: Double
        var out_per_s: Double
        /// Bulk IN completions that held only Wi-Fi 6 Trigger frames and went straight back to the dongle.
        var filtered_per_s: Double

        struct Route: Decodable, Equatable, Hashable {
            var cidr: String
            /// "ok" or "conflict" (that prefix already goes elsewhere)
            var state: String
            var gateway: String
            var interface: String
        }

        private enum CodingKeys: String, CodingKey {
            case pid, active, usb, device, device_error, guest, guest_interface, client, client_seconds, imports
            case in_mbps, out_mbps, max_out_ms, oldest_out_ms, errors, stalls, resets, routes
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
            pid = try c.decode(Int32.self, forKey: .pid)
            active = flag(.active)
            usb = text(.usb)
            device = text(.device)
            device_error = text(.device_error)
            guest = text(.guest)
            guest_interface = text(.guest_interface)
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
            routes = (try? c.decode([Route].self, forKey: .routes)) ?? []
            urbs_per_s = number(.urbs_per_s)
            control_per_s = number(.control_per_s)
            in_per_s = number(.in_per_s)
            out_per_s = number(.out_per_s)
            filtered_per_s = number(.filtered_per_s)
        }
    }

    /// nil while the daemon is not running.
    static func status() -> Status? {
        guard let data = FileManager.default.contents(atPath: statusPath),
              let status = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        // A root process answers kill(0) with EPERM: it exists.
        guard kill(status.pid, 0) == 0 || errno == EPERM else { return nil }
        return status
    }

    /// owner nil: the helper releases the dongle and removes its routes. rxFilter: the dongle
    /// is one of USBDevice.rtw88IDs and the Trigger frame filter is on.
    static func writeConfig(owner: Int32?, usb: String, guest: String?, routes: [String], rxFilter: Bool = false) {
        var lines = ["# Written by GodseonDongle; read by \(label)."]
        if let owner { lines.append("owner=\(owner)") }
        lines.append("usb=\(usb)")
        if let guest { lines.append("guest=\(guest)") }
        lines += routes.map { "route=\($0)" }
        if rxFilter { lines.append("rx_filter=rtw88") }
        let text = lines.joined(separator: "\n") + "\n"
        let url = configURL
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func install() async throws {
        guard let directory = bundledDirectory else { throw HelperError.missingBundle }
        // Only a first install needs the file; rewriting it on an update would make the
        // running helper drop the dongle and the routes for a moment.
        if !FileManager.default.fileExists(atPath: configURL.path) {
            writeConfig(owner: nil, usb: "0bda:b812", guest: nil, routes: [])
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
