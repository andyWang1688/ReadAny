// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "ShudengCoreBridge",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShudengCoreBridge", targets: ["ShudengCoreBridge"])
    ],
    targets: [
        .target(
            name: "ShudengCoreBridge",
            resources: [.copy("Resources/bridge-shim.js"), .copy("Resources/app-bootstrap.js")],
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "ShudengCoreBridgeTests",
            dependencies: ["ShudengCoreBridge"]
        ),
    ]
)
