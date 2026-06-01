// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Squirrel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SquirrelCore", targets: ["SquirrelCore"]),
        // Product name differs from target name to keep three distinct binary
        // names that don't collide on case-insensitive filesystems (APFS/HFS+).
        // The .app bundle still exposes the menu-bar binary as `Squirrel`;
        // see build-app.sh.
        .executable(name: "SquirrelMenuBar", targets: ["Squirrel"]),
        .executable(name: "squirrel-hook", targets: ["SquirrelHook"]),
        .executable(name: "squirrel-mcp", targets: ["SquirrelMCP"])
    ],
    targets: [
        .target(
            name: "SquirrelCore",
            path: "Sources/SquirrelCore"
        ),
        .executableTarget(
            name: "Squirrel",
            dependencies: ["SquirrelCore"],
            path: "Sources/Squirrel"
        ),
        .executableTarget(
            name: "SquirrelHook",
            dependencies: ["SquirrelCore"],
            path: "Sources/SquirrelHook"
        ),
        .executableTarget(
            name: "SquirrelMCP",
            dependencies: ["SquirrelCore"],
            path: "Sources/SquirrelMCP"
        )
    ]
)
