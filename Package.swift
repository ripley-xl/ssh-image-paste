// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SSHImagePaste",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ssh-image-paste",
            targets: ["ssh-image-paste"]
        ),
        .executable(
            name: "ssh-image-paste-daemon",
            targets: ["ssh-image-paste-daemon"]
        ),
        .library(
            name: "SSHImagePasteCore",
            targets: ["SSHImagePasteCore"]
        )
    ],
    targets: [
        .target(
            name: "SSHImagePasteCore"
        ),
        .executableTarget(
            name: "ssh-image-paste",
            dependencies: ["SSHImagePasteCore"]
        ),
        .executableTarget(
            name: "ssh-image-paste-daemon",
            dependencies: ["SSHImagePasteCore"]
        ),
        .testTarget(
            name: "SSHImagePasteCoreTests",
            dependencies: ["SSHImagePasteCore"]
        )
    ]
)
