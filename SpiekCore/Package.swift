// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpiekCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SpiekCore", targets: ["SpiekCore"])
    ],
    targets: [
        // Zero external dependencies on purpose: every byte of the consensus-
        // critical path (secp256k1, ECDSA, AES-GCM, hashing) is implemented in
        // this package and pinned by the reference vectors in the test target,
        // which were generated from the original JavaScript implementation.
        .target(
            name: "SpiekCore",
            linkerSettings: [.linkedFramework("Security", .when(platforms: [.iOS, .macOS]))]
        ),
        .testTarget(
            name: "SpiekCoreTests",
            dependencies: ["SpiekCore"],
            resources: [.process("Resources")]
        ),
    ]
)
