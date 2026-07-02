// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QwenAudiobookMaker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QwenAudiobookMaker", targets: ["QwenAudiobookMaker"])
    ],
    targets: [
        .executableTarget(
            name: "QwenAudiobookMaker",
            path: "Sources/QwenAudiobookMaker"
        )
    ]
)
