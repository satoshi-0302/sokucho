// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sokucho-native",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SokuchoNative", targets: ["SokuchoNative"])
    ],
    targets: [
        .executableTarget(
            name: "SokuchoNative",
            path: "Sources/SokuchoNative"
        ),
    ]
)
