// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PushupCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PushupCore", targets: ["PushupCore"]),
        .executable(name: "pushup-eval", targets: ["pushup-eval"]),
    ],
    targets: [
        .target(name: "PushupCore"),
        // Synthetic pose and session generators. Shared by the tests and the
        // evaluation tool, deliberately not exported as a product.
        .target(name: "PushupSynth", dependencies: ["PushupCore"]),
        // Offline evaluation logic, kept out of the executable so it can be tested.
        .target(name: "PushupEval", dependencies: ["PushupCore", "PushupSynth"]),
        .executableTarget(name: "pushup-eval", dependencies: ["PushupCore", "PushupSynth", "PushupEval"]),
        .testTarget(
            name: "PushupCoreTests",
            dependencies: ["PushupCore", "PushupSynth"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PushupEvalTests",
            dependencies: ["PushupCore", "PushupSynth", "PushupEval"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
