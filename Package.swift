// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ASCIIRT",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ASCIIRT", targets: ["ASCIIRT"])
    ],
    targets: [
        // Struct compartido Swift <-> Metal. Ver Sources/ShaderTypes/include/RenderParams.h
        .target(name: "ShaderTypes"),
        .executableTarget(
            name: "ASCIIRT",
            dependencies: ["ShaderTypes"],
            // Los .metal no los maneja SwiftPM: Scripts/build.sh los copia al
            // bundle y ShaderLibrary los compila en runtime.
            exclude: ["Shaders"]
        )
    ]
)
