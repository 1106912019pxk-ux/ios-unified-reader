// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReadiumResolutionSpike",
    platforms: [
        .iOS(.v15)
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        ),
        .package(
            url: "https://github.com/readium/swift-toolkit.git",
            exact: "3.8.0"
        )
    ]
)
