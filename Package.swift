// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LectureScribe",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "LectureScribe", targets: ["LectureScribe"])],
    targets: [
        .executableTarget(name: "LectureScribe"),
        .testTarget(name: "LectureScribeTests", dependencies: ["LectureScribe"])
    ],
    swiftLanguageModes: [.v6]
)
