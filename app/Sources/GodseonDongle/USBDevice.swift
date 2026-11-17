// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation
import IOKit

/// Read-only look at the dongle in the I/O Registry (no privileges needed).
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

    /// "0bda:b812" -> the negotiated speed, nil when the device is not plugged in.
    static func speed(of id: String) -> Speed? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let vid = Int(parts[0], radix: 16), let pid = Int(parts[1], radix: 16),
              let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        match["idVendor"] = vid
        match["idProduct"] = pid
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "Device Speed" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return Speed(rawValue: value.intValue)
    }
}
