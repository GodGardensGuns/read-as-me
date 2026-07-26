// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReadAsMe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ReadAsMe", targets: ["ReadAsMe"])
    ],
    targets: [
        .executableTarget(
            name: "ReadAsMe",
            path: "Sources/ReadAsMe"
        ),
        .testTarget(
            name: "ReadAsMeTests",
            dependencies: ["ReadAsMe"],
            path: "Tests/ReadAsMeTests"
        )
    ]
)
