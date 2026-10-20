// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoteBankKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NoteBankKit", targets: ["NoteBankKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "NoteBankKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "NoteBankKitTests", dependencies: ["NoteBankKit", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
