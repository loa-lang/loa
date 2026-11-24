// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LoaTests",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "t_loa", targets: ["LoaTests"]),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Testing.git", branch: "master"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "LoaTests",
            dependencies: [
                .product(name: "Loa", package: "Loa"),
                .product(name: "Testing", package: "Testing"),
            ]
        ),
    ]
)
