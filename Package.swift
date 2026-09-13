// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LectureScribe",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "LectureScribe", targets: ["LectureScribe"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")
    ],
    targets: [
        .executableTarget(name: "LectureScribe", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift")
        ]),
        .testTarget(name: "LectureScribeTests", dependencies: ["LectureScribe"])
    ],
    swiftLanguageModes: [.v6]
)
