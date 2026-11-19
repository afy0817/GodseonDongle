// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation

/// What the user chose for one device, kept in UserDefaults ("Devices", JSON) under its key.
struct DeviceSetting: Codable, Equatable {
    var kind: USBDevice.Kind
    /// The product name when last seen; empty for one never seen.
    var name: String
    /// vendor:product when last seen (a phone's changes with its USB mode).
    var usbID: String
    /// Handed to the VM while plugged in. At most one device of each kind has it.
    var use: Bool
    /// A phone: the Mac's internet goes through it.
    var internet: Bool = true
    /// An rtw88 dongle: the helper keeps Wi-Fi 6 Trigger frames away from the VM.
    var rxFilter: Bool = true
    /// A dongle: TCP segmentation offload off Mac-wide while it is in use. nil (saved by an
    /// app before the setting) is on.
    var tsoOff: Bool? = nil
}

enum DeviceKey {
    /// A dongle by its USB ID; a phone by vendor and serial number, which stay the same when
    /// switching tethering on changes its product ID.
    static func of(_ info: USBDevice.Info, kind: USBDevice.Kind) -> String {
        switch kind {
        case .wifi:
            return "wifi:\(info.usbID)"
        case .tether:
            guard let serial = info.safeSerial else { return "phone:\(info.usbID)" }
            return String(format: "phone:%04x:", info.vendorID) + serial
        }
    }
}

/// One row of the device list: a device plugged in now, or one set up earlier.
struct DeviceItem: Identifiable, Equatable {
    let key: String
    let kind: USBDevice.Kind
    /// nil while it is not plugged in.
    let plugged: USBDevice.Info?
    /// nil for a device never set up (it is not used).
    let setting: DeviceSetting?
    /// A phone with USB tethering on (see AppModel.devices).
    let tethering: Bool

    var id: String { key }
    var use: Bool { setting?.use ?? false }
    var usbID: String { plugged?.usbID ?? setting?.usbID ?? "" }
    var internet: Bool { setting?.internet ?? true }
    var rxFilter: Bool { setting?.rxFilter ?? true }
    var tsoOff: Bool { setting?.tsoOff ?? true }
    var filterApplies: Bool { kind == .wifi && USBDevice.rtw88IDs.contains(usbID) }

    var name: String {
        let name = plugged?.name.isEmpty == false ? plugged!.name : setting?.name ?? ""
        if !name.isEmpty { return name }
        return kind == .wifi ? t("USB Wi-Fi 동글") : t("안드로이드 폰")
    }
}

enum DeviceStore {
    private static let key = "Devices"

    /// nil when nothing was ever saved (a first run, or an app from before the device list).
    static func load() -> [String: DeviceSetting]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([String: DeviceSetting].self, from: data)
    }

    static func save(_ settings: [String: DeviceSetting]) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
