// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSDKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GSDModel", targets: ["GSDModel"]),
        .library(name: "GSDStore", targets: ["GSDStore"]),
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
        .testTarget(name: "GSDModelTests", dependencies: ["GSDModel"]),
        .testTarget(name: "GSDStoreTests", dependencies: ["GSDStore"]),
    ]
)
