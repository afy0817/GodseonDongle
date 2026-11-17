// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "GodseonDongle",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GodseonDongle",
            path: "Sources/GodseonDongle",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Virtualization"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
