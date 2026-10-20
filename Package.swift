// swift-tools-version:6.0
// Rondo — clean-room macOS menu-bar file converter. See docs/ARCHITECTURE.md.
import PackageDescription

let kit: Target.Dependency = "RondoKit"

let package = Package(
    name: "Rondo",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Rondo", targets: ["Rondo"]),
        .executable(name: "rondo-cli", targets: ["RondoCLI"]),
    ],
    targets: [
        // Contracts + support (orchestrator-owned)
        .target(name: "RondoKit"),

        // Engines
        .target(name: "ImageEngine", dependencies: [kit]),
        .target(name: "PDFEngine", dependencies: [kit]),
        .target(name: "MediaEngine", dependencies: [kit]),
        .target(name: "DocEngine", dependencies: [kit]),

        // UI modules
        .target(name: "RondoInteraction", dependencies: [kit]),
        .target(name: "RondoShell", dependencies: [kit]),
        .target(name: "ImageEditorUI", dependencies: [kit, "ImageEngine"]),
        .target(name: "MediaEditorUI", dependencies: [kit, "MediaEngine"]),
        .target(name: "PDFOrganizerUI", dependencies: [kit, "PDFEngine"]),

        // Executables (orchestrator-owned)
        .executableTarget(
            name: "Rondo",
            dependencies: [
                kit, "ImageEngine", "PDFEngine", "MediaEngine", "DocEngine",
                "RondoInteraction", "RondoShell",
                "ImageEditorUI", "MediaEditorUI", "PDFOrganizerUI",
            ]
        ),
        .executableTarget(
            name: "RondoCLI",
            dependencies: [kit, "ImageEngine", "PDFEngine", "MediaEngine", "DocEngine"],
            path: "Sources/rondo-cli"
        ),

        // Tests — run via scripts/test.sh (Swift Testing needs CLT framework flags)
        .testTarget(name: "RondoKitTests", dependencies: [kit]),
        .testTarget(name: "ImageEngineTests", dependencies: [kit, "ImageEngine"]),
        .testTarget(name: "PDFEngineTests", dependencies: [kit, "PDFEngine"]),
        .testTarget(name: "MediaEngineTests", dependencies: [kit, "MediaEngine"]),
        .testTarget(name: "DocEngineTests", dependencies: [kit, "DocEngine"]),
        .testTarget(name: "RondoInteractionTests", dependencies: [kit, "RondoInteraction"]),
        .testTarget(name: "RondoShellTests", dependencies: [kit, "RondoShell"]),
        .testTarget(name: "ImageEditorUITests", dependencies: [kit, "ImageEditorUI"]),
        .testTarget(name: "MediaEditorUITests", dependencies: [kit, "MediaEditorUI"]),
        .testTarget(name: "PDFOrganizerUITests", dependencies: [kit, "PDFOrganizerUI"]),
    ],
    swiftLanguageModes: [.v5]
)
