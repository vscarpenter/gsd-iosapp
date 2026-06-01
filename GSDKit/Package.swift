// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSDKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GSDModel", targets: ["GSDModel"]),
        .library(name: "GSDStore", targets: ["GSDStore"]),
        .library(name: "GSDSync", targets: ["GSDSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "GSDModel"),
        .target(
            name: "GSDStore",
            dependencies: [
                "GSDModel",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "GSDSync", dependencies: ["GSDModel", "GSDStore"]),
        .testTarget(name: "GSDModelTests", dependencies: ["GSDModel"]),
        .testTarget(name: "GSDStoreTests", dependencies: ["GSDStore"]),
        .testTarget(
            name: "GSDSyncTests",
            dependencies: ["GSDSync"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
