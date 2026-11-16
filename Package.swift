// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShortMaker",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Lokale Spracherkennung (Whisper über Core ML)
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "ShortMaker",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            path: "Sources/ShortMaker"
        ),
    ]
)
