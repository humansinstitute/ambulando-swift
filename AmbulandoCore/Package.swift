// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmbulandoCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "AmbulandoCore", targets: ["AmbulandoCore"])],
    dependencies: [
        // Same pinned secp256k1 implementation as the shipped NoteToSelf app.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "AmbulandoCore",
            dependencies: [.product(name: "P256K", package: "swift-secp256k1")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "AmbulandoCoreTests", dependencies: ["AmbulandoCore"]),
    ]
)
