// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Loa",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Loa", targets: ["Loa"]),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Errors.git", branch: "master"),
        .package(url: "https://github.com/lco-langs/Frame.git", branch: "master"),
        .package(url: "https://github.com/swift-langs/Grammar.git", branch: "master"),
        .package(url: "https://github.com/swift-langs/Parsing.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Position.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "Loa",
            dependencies: [
                .product(name: "Errors", package: "Errors"),
                .product(name: "Frame", package: "Frame"),
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "GrammarParsing", package: "Parsing"),
                .product(name: "Parsing", package: "Parsing"),
                .product(name: "Position", package: "Position"),
            ]
        ),
    ]
)
