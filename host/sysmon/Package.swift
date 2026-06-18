// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "USBSysmon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "sysmon", targets: ["sysmon"])
    ],
    targets: [
        .executableTarget(
            name: "sysmon",
            path: "sysmon",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "sysmonTests",
            dependencies: ["sysmon"],
            path: "Tests/sysmonTests"
        )
    ]
)
