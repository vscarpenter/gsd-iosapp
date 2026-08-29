// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSDKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GSDModel", targets: ["GSDModel"]),
        .library(name: "GSDStore", targets: ["GSDStore"]),
        .library(name: "GSDSync", targets: ["GSDSync"]),
        .library(name: "GSDSnapshot", targets: ["GSDSnapshot"]),
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
        .target(name: "GSDSnapshot", dependencies: ["GSDModel"]),
        .testTarget(
            name: "GSDModelTests",
            dependencies: ["GSDModel"],
            // The capture-parser corpus is a byte-identical copy of the web repo's
            // tests/fixtures/cross-platform/capture-parser-corpus.json — both suites run
            // every case so the two parser implementations cannot drift apart unnoticed.
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GSDStoreTests",
            dependencies: ["GSDStore"],
            // The cross-platform backup fixture is a byte-identical copy of the web repo's
            // tests/fixtures/cross-platform/. Both suites read the same file so neither can
            // drift into passing against a shape the other never writes.
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GSDSyncTests",
            dependencies: ["GSDSync"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "GSDSnapshotTests", dependencies: ["GSDSnapshot"]),
    ]
)
