// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation

/// Which build is running: the app's version and commit from Info.plist (app/build_app.sh
/// writes them) and the VM image in the bundle from vm_assets/manifest.json (GodseonDongle-VM).
enum AppInfo {
    /// "0.3.0": the v* tag the app was built from.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    /// "b4967ea", or "b4967ea-dirty" for a build with uncommitted changes; nil when the build had
    /// no git checkout, and for a bare `swift run`.
    static let commit = Bundle.main.object(forInfoDictionaryKey: "GodseonCommit") as? String

    /// "0.3.0 (b4967ea)"
    static var versionText: String { commit.map { "\(version) (\($0))" } ?? version }

    /// "GodseonDongle-VM 0.1.0 · 리눅스 7.3.5"; nil when the bundle has no readable manifest.
    static var vmImageText: String? {
        guard let image = vmImage else { return nil }
        var text = "\(image.name) \(image.version)"
        if let kernel = image.kernel { text += " · " + t("리눅스 \(kernel)") }
        return text
    }

    /// The same for the diagnostics report, in English whatever the app's language.
    static var report: String {
        var text = "GodseonDongle \(versionText)\n"
        if let image = vmImage {
            text += "VM image: \(image.name) \(image.version)" + (image.kernel.map { ", Linux \($0)" } ?? "") + "\n"
        }
        return text
    }

    private static let vmImage: (name: String, version: String, kernel: String?)? = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "vm_assets"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = manifest["version"] as? String else { return nil }
        // "7.3.5-0-stable" -> "7.3.5"
        let kernel = (manifest["kernel"] as? String).map { release in String(release.prefix { $0 != "-" }) }
        return (name: manifest["name"] as? String ?? "VM", version: version, kernel: kernel)
    }()
}
