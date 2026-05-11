// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JarvisBridge",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "JarvisBridge",
            targets: ["JarvisBridge"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "JarvisBridge",
            path: "JarvisBridge/Sources"
        ),
    ]
)
