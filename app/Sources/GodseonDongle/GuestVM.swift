// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation
import Virtualization

/// The guest: a RAM-only Linux (kernel + initramfs bundled in the app) on Virtualization.framework.
/// The dongle reaches it over USB/IP from the root helper; its control API listens on eth0:9408.
@MainActor
final class GuestVM: NSObject {
    enum State: Equatable {
        case stopped, starting, running, stopping
        case failed(String)
    }

    /// Fixed, so the VZ NAT DHCP server keeps handing the guest the same address.
    static let macAddress = "02:00:5E:10:00:66"

    private(set) var state: State = .stopped { didSet { if state != oldValue { onChange?() } } }
    /// The guest's address on the VZ NAT link, from its console marker.
    private(set) var address: String? { didSet { if address != oldValue { onChange?() } } }
    private(set) var startedAt: Date?
    var onChange: (() -> Void)?

    private var machine: VZVirtualMachine?
    private var consoleOutput: Pipe?
    private var consoleInput: Pipe?
    private var pending = Data()
    private var log: FileHandle?

    static var consoleLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GodseonDongle/console.log")
    }

    enum VMError: LocalizedError {
        case missingAssets
        var errorDescription: String? { t("앱 안에 VM 이미지가 없어요. 앱을 다시 빌드해 주세요.") }
    }

    func start(token: String, country: String) throws {
        switch state {
        case .stopped, .failed: break
        default: return
        }
        guard let assets = Bundle.main.url(forResource: "vm_assets", withExtension: nil),
              FileManager.default.fileExists(atPath: assets.appendingPathComponent("Image-lts").path) else {
            throw VMError.missingAssets
        }
        let bootLoader = VZLinuxBootLoader(kernelURL: assets.appendingPathComponent("Image-lts"))
        bootLoader.initialRamdiskURL = assets.appendingPathComponent("initramfs-thrurndis-wifi")
        bootLoader.commandLine = [
            "console=hvc0", "rdinit=/sbin/init", "modules=virtio_pci,virtio_mmio,virtio_console",
            "godseon.usbip=gw/1-1", "thrurndis-wifi.token=\(token)", "thrurndis-wifi.country=\(country)",
        ].joined(separator: " ")

        let output = Pipe(), input = Pipe()
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: Self.debugConsoleInput() ?? input.fileHandleForReading,
            fileHandleForWriting: output.fileHandleForWriting)

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VZMACAddress(string: Self.macAddress)!

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.cpuCount = 1
        configuration.memorySize = 256 * 1024 * 1024
        configuration.bootLoader = bootLoader
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.serialPorts = [console]
        configuration.networkDevices = [network]
        try configuration.validate()

        openLog()
        pending = Data()
        address = nil
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        consoleOutput = output
        consoleInput = input

        let machine = VZVirtualMachine(configuration: configuration)   // runs on the main queue
        machine.delegate = self
        self.machine = machine
        state = .starting
        machine.start { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch result {
                case .success:
                    self.state = .running
                    self.startedAt = Date()
                case .failure(let error):
                    self.teardown(.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Development aid, off by default (`defaults write io.github.afy0817.GodseonDongle DebugConsole -bool true`):
    /// lines written to this FIFO are typed on the guest's root console; output lands in console.log.
    static var debugConsoleURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GodseonDongle/console.in")
    }

    private static func debugConsoleInput() -> FileHandle? {
        let path = debugConsoleURL.path
        guard UserDefaults.standard.bool(forKey: "DebugConsole") else {
            unlink(path)
            return nil
        }
        try? FileManager.default.createDirectory(at: debugConsoleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else { return nil }
        let fd = open(path, O_RDWR)          // read-write: the console never sees EOF
        return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    /// The guest keeps nothing on disk, so a hard stop loses nothing.
    func stop() async {
        guard let machine, state == .running || state == .starting else { return }
        state = .stopping
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            machine.stop { _ in continuation.resume() }
        }
        teardown(.stopped)
    }

    private func teardown(_ final: State) {
        consoleOutput?.fileHandleForReading.readabilityHandler = nil
        consoleOutput = nil
        consoleInput = nil
        machine = nil
        address = nil
        startedAt = nil
        try? log?.close()
        log = nil
        state = final
    }

    // MARK: Console

    private func openLog() {
        let url = Self.consoleLogURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)      // one boot per file
        log = try? FileHandle(forWritingTo: url)
    }

    private func consume(_ data: Data) {
        log?.write(data)
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0a) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // init-network's host contract: "THRURNDIS_VZNAT_IPV4=192.168.64.5"
            if let range = line.range(of: "THRURNDIS_VZNAT_IPV4=") {
                let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if IPv4.parse(value) != nil { address = value }
            }
        }
        if pending.count > 64 * 1024 { pending.removeAll() }
    }
}

extension GuestVM: VZVirtualMachineDelegate {
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { teardown(.stopped) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { teardown(.failed(message)) }
    }
}
