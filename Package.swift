// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clauwise",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Clauwise",
            path: "Sources/Clauwise"
        ),
        .testTarget(
            name: "ClauwiseTests",
            dependencies: ["Clauwise"],
            path: "Tests/ClauwiseTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
