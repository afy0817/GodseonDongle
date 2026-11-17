// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import CommonCrypto
import Foundation
import Security

enum Hex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// SSIDs are raw bytes; show them as UTF-8 when possible.
    static func decodeSSID(_ hex: String) -> String {
        guard let data = decode(hex), !data.isEmpty else { return "" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// What the guest needs to join one network. The passphrase never leaves the
/// Mac in clear text form except as the SAE password, which WPA3 requires.
struct WiFiCredential: Codable, Equatable {
    var ssid: String
    var password: String
    var hidden: Bool
    /// The manual IPv4 values; nil when none were entered.
    var staticIPv4: StaticIPv4? = nil
    /// Off: DHCP, while the manual values stay saved for later.
    var useStatic: Bool = true

    var ssidData: Data { Data(ssid.utf8) }

    enum ValidationError: LocalizedError {
        case ssid, password
        var errorDescription: String? {
            switch self {
            case .ssid: return t("네트워크 이름(SSID)은 1~32바이트여야 해요.")
            case .password: return t("비밀번호는 8~63자(또는 64자리 16진수 PSK)여야 해요.")
            }
        }
    }

    func validate() throws {
        guard (1...32).contains(ssidData.count) else { throw ValidationError.ssid }
        guard password.isEmpty || isRawPSK || (8...63).contains(password.utf8.count) else {
            throw ValidationError.password
        }
    }

    private var isRawPSK: Bool {
        // isHexDigit alone also takes fullwidth digits, which the VM rejects.
        password.count == 64 && password.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// WPA2 PSK = PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32).
    var pskHex: String {
        if password.isEmpty { return "" }
        if isRawPSK { return password.lowercased() }
        var key = [UInt8](repeating: 0, count: 32)
        let salt = [UInt8](ssidData)
        let status = password.withCString { passphrase in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), passphrase, strlen(passphrase),
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 4096,
                &key, key.count
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return Hex.encode(Data(key))
    }

    var saeHex: String {
        (password.isEmpty || isRawPSK) ? "" : Hex.encode(Data(password.utf8))
    }

    var formBody: String {
        var body = "ssid=\(Hex.encode(ssidData))&psk=\(pskHex)&sae=\(saeHex)&hidden=\(hidden ? 1 : 0)"
        if useStatic, let staticIPv4 { body += "&" + staticIPv4.formFields }
        return body
    }
}

/// Saved networks: the list (without passwords) lives in UserDefaults, the
/// passwords in the login Keychain.
enum CredentialStore {
    private static let service = "io.github.afy0817.GodseonDongle"
    private static let listKey = "SavedNetworks"

    struct Entry: Codable, Equatable, Identifiable {
        var ssid: String
        var hidden: Bool
        var staticIPv4: StaticIPv4?
        /// false keeps the manual values but uses DHCP; nil (older entries) counts as on.
        var useStatic: Bool?
        var id: String { ssid }
        /// The manual addressing in effect, nil for DHCP.
        var activeStaticIPv4: StaticIPv4? { (useStatic ?? true) ? staticIPv4 : nil }
    }

    static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func credential(for ssid: String) -> WiFiCredential? {
        guard let entry = entries().first(where: { $0.ssid == ssid }) else { return nil }
        return WiFiCredential(ssid: ssid, password: password(for: ssid) ?? "", hidden: entry.hidden,
                              staticIPv4: entry.staticIPv4, useStatic: entry.useStatic ?? true)
    }

    /// Most recently used first.
    static func save(_ credential: WiFiCredential) {
        var list = entries().filter { $0.ssid != credential.ssid }
        list.insert(Entry(ssid: credential.ssid, hidden: credential.hidden, staticIPv4: credential.staticIPv4,
                          useStatic: credential.useStatic), at: 0)
        store(list)
        setPassword(credential.password, for: credential.ssid)
    }

    /// Changes only the addressing of a saved network, keeping its place.
    static func setStaticIPv4(_ staticIPv4: StaticIPv4?, for ssid: String) {
        var list = entries()
        guard let index = list.firstIndex(where: { $0.ssid == ssid }) else { return }
        list[index].staticIPv4 = staticIPv4
        store(list)
    }

    private static func store(_ list: [Entry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: listKey)
    }

    static func remove(_ ssid: String) {
        store(entries().filter { $0.ssid != ssid })
        SecItemDelete(query(for: ssid) as CFDictionary)
    }

    private static func query(for ssid: String, service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
        ]
    }

    private static func password(for ssid: String) -> String? {
        storedPassword(for: ssid, service: service)
    }

    static func hasPassword(for ssid: String) -> Bool {
        var query = query(for: ssid)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func storedPassword(for ssid: String, service: String) -> String? {
        var query = query(for: ssid, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setPassword(_ password: String, for ssid: String) {
        SecItemDelete(query(for: ssid) as CFDictionary)
        guard !password.isEmpty else { return }
        var item = query(for: ssid)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "GodseonDongle: \(ssid)"
        SecItemAdd(item as CFDictionary, nil)
    }
}
