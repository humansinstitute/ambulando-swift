// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmbulandoCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "AmbulandoCore", targets: ["AmbulandoCore"])],
    dependencies: [
        // Same pinned secp256k1 implementation as the shipped NoteToSelf app.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
        // NIP-49 needs scrypt and XChaCha20-Poly1305, which neither CryptoKit nor swift-secp256k1 has. swift-sodium's Clibsodium
        // xcframework is a SODIUM_LIBRARY_MINIMAL build without scrypt, so it cannot be used; CryptoSwift ships both primitives.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", exact: "1.9.0"),
    ],
    targets: [
        .target(
            name: "AmbulandoCore",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "AmbulandoCoreTests", dependencies: ["AmbulandoCore"], exclude: ["Fixtures"]),
    ]
)
