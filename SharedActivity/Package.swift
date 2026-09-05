// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SharedActivity",
    platforms: [.iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "SharedActivity", targets: ["SharedActivity"]),
    ],
    targets: [
        .target(
            name: "SharedActivity",
            path: "Sources/SharedActivity"
        ),
    ]
)
