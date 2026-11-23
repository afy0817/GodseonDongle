// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation
import IOKit

/// Read-only look at the Mac's USB devices in the I/O Registry (no privileges needed). The
/// devices the helper holds stay listed, interfaces included.
enum USBDevice {
    enum Speed: Int {
        case low = 0, full, high, superSpeed, superSpeedPlus

        var label: String {
            switch self {
            case .low: return "USB 1.0"
            case .full: return "USB 1.1"
            case .high: return "USB 2.0"
            case .superSpeed, .superSpeedPlus: return "USB 3"
            }
        }

        /// Full speed caps the dongle at a few Mbit/s, whatever the Wi-Fi link does.
        var isSlow: Bool { rawValue <= Speed.full.rawValue }
    }

    /// What a device is to the app.
    enum Kind: String, Codable {
        /// A USB Wi-Fi dongle, driven by Linux in the VM.
        case wifi
        /// An Android phone, used for its USB tethering (RNDIS).
        case tether
    }

    /// One device plugged into the Mac.
    struct Info: Equatable {
        var vendorID: Int
        var productID: Int
        var name: String
        var serial: String
        var speed: Speed?
        /// USB tethering is on: the phone offers an RNDIS network function.
        var hasRNDIS: Bool
        /// adb or MTP: an Android phone, tethering or not.
        var isAndroid: Bool

        var usbID: String { String(format: "%04x:%04x", vendorID, productID) }

        /// The serial number, when the helper's config can carry it (a phone keeps it in every
        /// USB mode, while its product ID changes).
        var safeSerial: String? {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
            guard (1...64).contains(serial.count), serial.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return serial
        }
    }

    /// Dongles the Linux rtw88 USB driver handles (the device tables of rtw8822bu.c, rtw8821cu.c
    /// and rtw8822cu.c in Linux 7.3). The helper understands their receive format, so it can
    /// keep the Wi-Fi 6 Trigger frames these chips pass up away from the VM (rx_filter=rtw88).
    static let rtw88IDs: Set<String> = [
        // rtw8822bu
        "0411:03d0", "0411:03d1", "04ca:8602", "056e:4011", "0846:9055", "0b05:1841", "0b05:184c",
        "0b05:1870", "0b05:1874", "0b05:19aa", "0bda:2102", "0bda:b812", "0bda:b81a", "0bda:b82c",
        "0e66:0025", "13b1:0043", "13b1:0045", "2001:331c", "2001:331e", "2001:331f", "2001:3322",
        "20f4:805a", "20f4:808a", "2357:0115", "2357:0116", "2357:0117", "2357:012d", "2357:012e",
        "2357:0138", "2c4e:0107", "2c4e:010a", "7392:b822", "7392:c822", "7392:d822", "7392:e822",
        "7392:f822",
        // rtw8821cu
        "0bda:2006", "0bda:8731", "0bda:8811", "0bda:b820", "0bda:b82b", "0bda:c80c", "0bda:c811",
        "0bda:c820", "0bda:c821", "0bda:c82a", "0bda:c82b", "2001:331d", "2c4e:0105", "7392:c811",
        "7392:d811",
        // rtw8822cu (13b1:0043 is in the rtw8822bu table too)
        "0bda:c812", "0bda:c82c", "0bda:c82e", "0bda:d820", "0bda:d82b", "2001:3329"
    ]

    /// Every USB ID a Wi-Fi driver in the VM claims, from the image's manifest (written by
    /// builder/build_assets.py in GodseonDongle-VM). An image from before the list falls back to rtw88IDs.
    static let wifiIDs: Set<String> = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "vm_assets"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = manifest["wifi_usb_ids"] as? [String], !ids.isEmpty else { return rtw88IDs }
        return Set(ids.map { $0.lowercased() })
    }()

    /// Every device plugged in now, in registry order.
    static func all() -> [Info] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [Info] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let p = properties(service)
            guard let vendor = p["idVendor"] as? Int, let product = p["idProduct"] as? Int else { continue }
            var info = Info(vendorID: vendor, productID: product,
                            name: (p["USB Product Name"] as? String ?? p["kUSBProductString"] as? String ?? "")
                                .trimmingCharacters(in: .whitespaces),
                            serial: p["USB Serial Number"] as? String ?? p["kUSBSerialNumberString"] as? String ?? "",
                            speed: (p["Device Speed"] as? Int).flatMap(Speed.init(rawValue:)),
                            // A wireless controller (RNDIS) at the device level: macOS may leave it
                            // unconfigured, so its interfaces never show up below.
                            hasRNDIS: p["bDeviceClass"] as? Int == 0xE0, isAndroid: false)
            forEachInterface(of: service) { interface in
                let c = interface["bInterfaceClass"] as? Int ?? -1
                let s = interface["bInterfaceSubClass"] as? Int ?? -1
                let r = interface["bInterfaceProtocol"] as? Int ?? -1
                // RNDIS as Android, Windows and Linux gadgets announce it (the rndis_host match table)
                if (c == 0xE0 && s == 0x01 && r == 0x03) || (c == 0xEF && s == 0x04 && r == 0x01)
                    || (c == 0x02 && s == 0x02 && r == 0xFF) {
                    info.hasRNDIS = true
                }
                if (c == 0xFF && s == 0x42 && r == 0x01) || (interface["kUSBString"] as? String) == "MTP" {
                    info.isAndroid = true
                }
            }
            devices.append(info)
        }
        return devices
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private static func forEachInterface(of device: io_service_t, _ body: ([String: Any]) -> Void) {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 { body(properties(child)) }
        }
    }
}

/// Calls back on the main queue whenever a USB device appears or goes away, such as a phone
/// coming back in another USB mode once tethering is switched on.
@MainActor
final class USBWatcher {
    private let port: IONotificationPortRef
    private var iterators: [io_iterator_t] = []
    fileprivate let onChange: @MainActor () -> Void

    init?(onChange: @escaping @MainActor () -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        self.onChange = onChange
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            usbWatcherDrain(iterator)
            guard let refcon else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            // each call consumes the matching dictionary it gets
            guard IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOUSBHostDevice"), callback, refcon,
                                                   &iterator) == KERN_SUCCESS else { continue }
            usbWatcherDrain(iterator)       // arms the notification
            iterators.append(iterator)
        }
    }

    deinit {
        for iterator in iterators { IOObjectRelease(iterator) }
        IONotificationPortDestroy(port)
    }
}

private func usbWatcherDrain(_ iterator: io_iterator_t) {
    while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
}
