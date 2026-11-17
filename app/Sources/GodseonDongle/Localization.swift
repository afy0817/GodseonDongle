// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation
import Observation

/// The app's language. Every string in the code is Korean, the source language; English comes
/// from Resources/en.lproj/GodseonDongle.strings. Views follow a change at once: t() reads
/// `code`, and SwiftUI re-renders whatever read it.
@Observable
final class AppLanguage {
    enum Choice: String, CaseIterable, Identifiable {
        case system, korean = "ko", english = "en"
        var id: String { rawValue }
    }

    enum Code: String { case ko, en }

    static let shared = AppLanguage()
    private static let defaultsKey = "AppLanguage"

    private(set) var choice: Choice
    private(set) var code: Code

    private init() {
        let choice = Choice(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .system
        self.choice = choice
        code = Self.resolve(choice)
    }

    func select(_ choice: Choice) {
        guard choice != self.choice else { return }
        self.choice = choice
        let defaults = UserDefaults.standard
        // AppleLanguages in the app's own domain is macOS's per-app language: the menus AppKit
        // draws itself (the app menu, Services) follow it from the next launch.
        if choice == .system {
            defaults.removeObject(forKey: Self.defaultsKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(choice.rawValue, forKey: Self.defaultsKey)
            defaults.set([choice.rawValue], forKey: "AppleLanguages")
        }
        code = Self.resolve(choice)
    }

    /// System: the first Korean or English entry in the app's own language list (System
    /// Settings > General > Language & Region > Applications) or else the global one; English
    /// when neither language is listed.
    private static func resolve(_ choice: Choice) -> Code {
        switch choice {
        case .korean: return .ko
        case .english: return .en
        case .system:
            let defaults = UserDefaults.standard
            let own = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0)?["AppleLanguages"] } as? [String]
            let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            for language in own ?? global ?? Locale.preferredLanguages {
                if language.hasPrefix("ko") { return .ko }
                if language.hasPrefix("en") { return .en }
            }
            return .en
        }
    }
}

enum Translations {
    /// Korean source string -> English. Empty when the table is missing (a bare `swift run`).
    static let english: [String: String] = {
        guard let url = Bundle.main.url(forResource: "GodseonDongle", withExtension: "strings",
                                        subdirectory: nil, localization: "en"),
              let table = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return table
    }()
}

/// t("연결됨"), t("\(ssid)에 연결하는 중…"): the string in the app's language. In the lookup key
/// each interpolated value is %@; a translation can reorder them as %1$@, %2$@.
func t(_ text: LocalizedText) -> String {
    let template = AppLanguage.shared.code == .en ? (Translations.english[text.key] ?? text.key) : text.key
    return text.arguments.isEmpty ? template : LocalizedText.fill(template, with: text.arguments)
}

/// For a key that is a value rather than a literal.
func t(key: String) -> String {
    AppLanguage.shared.code == .en ? (Translations.english[key] ?? key) : key
}

struct LocalizedText: ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + 2 * interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) { key += literal }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append("\(value)")
        }

        @available(*, deprecated, message: "unwrap the optional before interpolating it")
        mutating func appendInterpolation<T>(_ value: T?) {
            key += "%@"
            arguments.append(value.map { "\($0)" } ?? "")
        }
    }

    /// Replaces %@ (in order) and %N$@ (by position); any other % stays as it is.
    static func fill(_ template: String, with arguments: [String]) -> String {
        var result = ""
        var next = 0
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else { result.append(chars[i]); i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
            if j == i + 1, j < chars.count, chars[j] == "@" {
                if next < arguments.count { result += arguments[next] }
                next += 1
                i = j + 1
            } else if j > i + 1, j + 1 < chars.count, chars[j] == "$", chars[j + 1] == "@",
                      let position = Int(String(chars[(i + 1)..<j])), position >= 1 {
                if position <= arguments.count { result += arguments[position - 1] }
                i = j + 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }
}
